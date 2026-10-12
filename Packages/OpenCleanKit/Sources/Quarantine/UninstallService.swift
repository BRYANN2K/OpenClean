import Foundation
import Privilege
import RuleKit
import ScanEngine

public enum UninstallOutcome: Sendable {
    /// Nothing was moved and no session was created.
    case refused(UninstallRefusal)
    /// One quarantine session holding the app (entry 0) and the leftovers.
    case finished(RemovalReport)
}

/// What to uninstall: the inventory snapshot of the bundle and the leftovers the user ticked.
public struct UninstallRequest: Sendable {
    public let bundle: ScanItem
    public let bundleID: String
    public let leftovers: [ScanItem]
    /// The bundle is root-owned or not writable by the user (`AppStatus.needsAdministrator`): it is moved
    /// by `AppBundleAdminMove` after an administrator password prompt instead of by `FileManager`.
    public let requiresAdministrator: Bool

    public init(bundle: ScanItem, bundleID: String, leftovers: [ScanItem], requiresAdministrator: Bool = false) {
        self.bundle = bundle
        self.bundleID = bundleID
        self.leftovers = leftovers
        self.requiresAdministrator = requiresAdministrator
    }
}

/// Moves an app and its leftovers into quarantine as one restorable session.
///
/// The bundle gets a one-request `UninstallBundleExemption`; everything else goes through the normal
/// `PreDeleteChecker` (deny-list, unchanged since listing, not open, app not running). If the bundle itself
/// would be skipped, the whole request is refused so leftovers are never removed for an app that stays.
///
/// For a bundle the user can't move (`requiresAdministrator`), the same checks run (minus "owned by you /
/// writable"), then only that one bundle is moved by `AppBundleAdminMove` with a password prompt. Leftovers
/// are moved afterwards, and only if the bundle reached quarantine. A cancelled prompt moves nothing.
public struct UninstallService: Sendable {
    public static let appRuleID = "uninstall.app"
    public static let leftoverRuleID = "uninstall.leftover"

    let store: QuarantineStore
    let denyList: DenyList
    let processChecker: any ProcessChecker
    let admin: any AdminExecutor
    /// Moves a bundle the user can't move; nil means such requests are refused (`.needsAdministrator`).
    let bundleAdmin: (any AppBundleAdminExecutor)?
    let trash: TrashOperation
    let deviceOf: @Sendable (String) -> Int32?

    public init(
        store: QuarantineStore, denyList: DenyList, processChecker: any ProcessChecker, admin: any AdminExecutor,
        bundleAdmin: (any AppBundleAdminExecutor)? = nil, trash: @escaping TrashOperation = Remover.systemTrash,
        deviceOf: @escaping @Sendable (String) -> Int32? = { FileStat.of($0)?.device }
    ) {
        self.store = store
        self.denyList = denyList
        self.processChecker = processChecker
        self.admin = admin
        self.bundleAdmin = bundleAdmin
        self.trash = trash
        self.deviceOf = deviceOf
    }

    public static func rule(id: String, bundleID: String) -> Rule {
        Rule(
            id: id, name: id == appRuleID ? "Application" : "App leftovers", category: .user,
            explain: "Moved to quarantine by the Uninstaller.", safety: .review, deleteMode: .quarantine,
            conditions: RuleConditions(appNotRunning: [bundleID]))
    }

    /// `openPaths` is the `lsof` snapshot (nil when it could not be taken: the request is then refused).
    public func uninstall(
        _ request: UninstallRequest, allowedFolders: [String], protectedBundleIDs: Set<String>,
        protectedPaths: [String], openPaths: Set<String>?, now: Date = .now
    ) throws -> UninstallOutcome {
        if request.requiresAdministrator && bundleAdmin == nil { return .refused(.needsAdministrator) }
        let exemption: UninstallBundleExemption
        switch UninstallBundleExemption.authorize(
            bundlePath: request.bundle.path, bundleID: request.bundleID, allowedFolders: allowedFolders,
            denyList: denyList, protectedBundleIDs: protectedBundleIDs, protectedPaths: protectedPaths,
            administrator: request.requiresAdministrator)
        {
        case .success(let granted): exemption = granted
        case .failure(let refusal): return .refused(refusal)
        }

        let library = denyList.home + "/Library"
        for leftover in request.leftovers {
            guard !leftover.reportOnly, pathIsWithin(leftover.path, library, caseInsensitive: true),
                canonicalPathKey(leftover.path) != canonicalPathKey(library),
                !pathIsWithin(leftover.path, request.bundle.path, caseInsensitive: true)
            else { return .refused(.leftoverOutsideLibrary(leftover.path)) }
        }

        let checker = PreDeleteChecker(
            denyList: denyList, processChecker: processChecker, openPaths: openPaths, exemption: exemption)
        let appRule = Self.rule(id: Self.appRuleID, bundleID: request.bundleID)
        if let reason = checker.check(request.bundle, rule: appRule) {
            return .refused(.skipped(reason))
        }

        let leftoverRule = Self.rule(id: Self.leftoverRuleID, bundleID: request.bundleID)
        var seen: Set<[UInt8]> = [canonicalPathKey(request.bundle.path)]
        var requests = [RemovalRequest(item: request.bundle, rule: appRule)]
        for leftover in request.leftovers where seen.insert(canonicalPathKey(leftover.path)).inserted {
            requests.append(RemovalRequest(item: leftover, rule: leftoverRule))
        }
        let remover = Remover(store: store, checker: checker, admin: admin, deviceOf: deviceOf, trash: trash)
        let adminBundle = bundleAdmin.flatMap { executor in
            request.requiresAdministrator
                ? AdminBundleMove(
                    executor: executor, bundleID: request.bundleID, applicationFolders: allowedFolders,
                    protectedPaths: protectedPaths)
                : nil
        }
        return .finished(try remover.remove(requests, now: now, adminBundle: adminBundle))
    }
}
