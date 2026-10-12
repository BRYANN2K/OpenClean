import Foundation
import Permissions
import Privilege
import Probes
import ProcessKit
import Quarantine
import RuleKit
import ScanEngine

/// The single entry point the app and the CLI use. Holds no mutable state.
public struct OpenCleanCoordinator: Sendable {
    public let home: String
    /// `home` with symlinks resolved; every safety check (deny-list, linter, path expansion) uses this,
    /// because scan items are canonical paths.
    let resolvedHome: String
    public let paths: AppPaths
    public let registry: ProbeRegistry
    public let bundledRulesDirectory: URL?
    let processChecker: any ProcessChecker
    let openFiles: any OpenFilesProvider
    let admin: any AdminExecutor
    let accessCheck: @Sendable () -> FullDiskAccessStatus
    let trash: TrashOperation

    public init(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        registry: ProbeRegistry = .standard,
        processChecker: any ProcessChecker = RunningProcessChecker(),
        openFiles: any OpenFilesProvider = LsofOpenFilesProvider(),
        admin: any AdminExecutor = OsascriptAdminExecutor(),
        fullDiskAccess: (@Sendable () -> FullDiskAccessStatus)? = nil,
        trash: @escaping TrashOperation = Remover.systemTrash
    ) {
        let givenHome = environment["OPENCLEAN_HOME"] ?? home
        self.home = givenHome
        let resolvedHome = realPath(givenHome) ?? givenHome
        self.resolvedHome = resolvedHome
        paths = AppPaths.standard(home: givenHome)
        self.registry = registry
        bundledRulesDirectory = RulesLocator.bundledDirectory(environment: environment)
        self.processChecker = processChecker
        self.openFiles = openFiles
        self.admin = admin
        accessCheck = fullDiskAccess ?? { FullDiskAccessChecker(home: resolvedHome).status() }
        self.trash = trash
    }

    public var settingsStore: SettingsStore { SettingsStore(url: paths.settingsFile) }
    public var store: QuarantineStore { QuarantineStore(root: paths.quarantine) }

    public func fullDiskAccessStatus() -> FullDiskAccessStatus { accessCheck() }

    public func makeLinter() -> RuleLinter { RuleLinter(home: resolvedHome, knownProbes: registry.ids) }

    public func loadRules(includeCaution: Bool) -> LoadedRules {
        var directories: [URL] = []
        if let bundledRulesDirectory { directories.append(bundledRulesDirectory) }
        directories.append(paths.userRules)
        var loaded = RuleCatalog.load(directories: directories, linter: makeLinter())
        if bundledRulesDirectory == nil {
            loaded.problems.insert("Bundled rule packs were not found. Reinstall, or set OPENCLEAN_RULES_DIR.", at: 0)
        }
        if !includeCaution { loaded.rules.removeAll { $0.safety == .caution } }
        return loaded
    }

    public func scan(
        _ rules: [Rule], settings: Settings, progress: AsyncStream<ScanProgress>.Continuation? = nil
    ) async -> ScanResult {
        let expander = PathExpander(home: resolvedHome)
        let excludes = settings.excludedPaths.map { path -> String in
            let expanded = expander.expand(path)
            return realPath(expanded) ?? expanded
        }
        let context = ScanContext(
            home: resolvedHome, hasFullDiskAccess: accessCheck() == .granted, processChecker: processChecker,
            userExcludes: excludes)
        return await ScanEngine(registry: registry).scan(rules, context: context, progress: progress)
    }

    public func execute(_ plan: CleanupPlan) throws -> RemovalReport {
        let openPaths = try? openFiles.openPaths()
        let checker = PreDeleteChecker(
            denyList: DenyList(home: resolvedHome), processChecker: processChecker, openPaths: openPaths)
        return try Remover(store: store, checker: checker, admin: admin, trash: trash).remove(plan.requests)
    }

    public func history() -> [SessionListing] { store.listSessions() }

    public func restore(sessionID: String, paths: Set<String>? = nil, onConflict: ConflictPolicy) throws
        -> RestoreReport
    {
        try RestoreService(store: store, trash: trash).restore(
            sessionID: sessionID, paths: paths, onConflict: onConflict)
    }

    @discardableResult
    public func purgeExpired(settings: Settings) -> [String] {
        Purger(store: store).purge(retentionDays: settings.clampedRetentionDays)
    }

    public func purgeSchedule() -> PurgeSchedule { PurgeSchedule(home: home) }
}
