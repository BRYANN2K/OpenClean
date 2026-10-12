import Foundation
import ProcessKit
import Quarantine
import RuleKit

public enum LoginItemsError: Error, Equatable, CustomStringConvertible {
    /// System agents and daemons are listed read-only.
    case readOnly(String)
    case invalidLabel(String)
    /// The plist isn't directly inside your LaunchAgents folder.
    case notActionable(String)
    case launchctlFailed(String)
    case quarantineFailed(String)

    public var description: String {
        switch self {
        case .readOnly(let label): "\(label) is installed for all users and can only be changed by an administrator"
        case .invalidLabel(let label): "\"\(label)\" is not a label OpenClean will pass to launchctl"
        case .notActionable(let path): "\(path) is not in your LaunchAgents folder"
        case .launchctlFailed(let message): "launchctl reported an error: \(message)"
        case .quarantineFailed(let message): message
        }
    }
}

/// What an action did, in words the UI can show.
public enum LaunchItemActionResult: Sendable, Equatable {
    case done
    /// The action worked, with a caveat (e.g. enabled but couldn't be started until next login).
    case doneWithNote(String)
}

/// The three folders launchd reads plists from.
public struct LaunchItemRoots: Sendable, Equatable {
    public var userAgents: String
    public var systemAgents: String
    public var systemDaemons: String

    public init(userAgents: String, systemAgents: String, systemDaemons: String) {
        self.userAgents = userAgents
        self.systemAgents = systemAgents
        self.systemDaemons = systemDaemons
    }

    public static func standard(home: String) -> LaunchItemRoots {
        LaunchItemRoots(
            userAgents: (home as NSString).appendingPathComponent("Library/LaunchAgents"),
            systemAgents: "/Library/LaunchAgents", systemDaemons: "/Library/LaunchDaemons")
    }

    func directory(for scope: LaunchItemScope) -> String {
        switch scope {
        case .user: userAgents
        case .systemAgent: systemAgents
        case .systemDaemon: systemDaemons
        }
    }
}

/// Lists launch agents/daemons with their state, and disables, enables or removes *user* agents.
public struct LoginItemsService: Sendable {
    let roots: LaunchItemRoots
    let uid: UInt32
    let runner: any CommandRunner
    let owners: OwnerResolver
    let installedApps: [InstalledApp]
    let quarantine: LaunchAgentQuarantine

    public init(
        roots: LaunchItemRoots, uid: UInt32 = getuid(), runner: any CommandRunner = ProcessCommandRunner(timeout: 10),
        installedApps: [InstalledApp], quarantineStore: QuarantineStore
    ) {
        self.roots = roots
        self.uid = uid
        self.runner = runner
        self.installedApps = installedApps
        owners = OwnerResolver(apps: installedApps)
        quarantine = LaunchAgentQuarantine(store: quarantineStore, agentsDirectory: roots.userAgents, currentUID: uid)
    }

    // MARK: Inventory

    public func inventory() -> LoginItemsInventory {
        var inventory = LoginItemsInventory()
        var definitions: [(path: String, scope: LaunchItemScope, definition: LaunchItemDefinition)] = []
        for scope in LaunchItemScope.allCases {
            let directory = roots.directory(for: scope)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for name in names.sorted() where name.hasSuffix(".plist") && !name.hasPrefix(".") {
                let path = (directory as NSString).appendingPathComponent(name)
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    definitions.append((path, scope, try LaunchItemParser.parse(data)))
                } catch let error as LaunchItemParseError {
                    inventory.unreadable.append(
                        UnreadableLaunchItem(path: path, scope: scope, reason: error.description))
                } catch {
                    inventory.unreadable.append(
                        UnreadableLaunchItem(path: path, scope: scope, reason: "could not be read"))
                }
            }
        }

        let guiList = run(LaunchctlCommand.list()).map { LaunchctlParser.parseList($0.stdoutText) }
        let guiDisabled = run(LaunchctlCommand.printDisabled(uid: uid)).map {
            LaunchctlParser.parseDisabled($0.stdoutText)
        }
        let systemDisabled = run(["print-disabled", "system"]).map { LaunchctlParser.parseDisabled($0.stdoutText) }
        inventory.launchctlAvailable = guiList != nil

        for entry in definitions {
            let label = entry.definition.label
            let loadState: LoadState
            let override: Bool?
            switch entry.scope {
            case .user, .systemAgent:
                if let guiList {
                    loadState = guiList[label].map { .loaded(pid: $0.pid) } ?? .notLoaded
                } else {
                    loadState = .unknown
                }
                override = guiDisabled?[label]
            case .systemDaemon:
                loadState = daemonState(label)
                override = systemDisabled?[label]
            }
            inventory.items.append(
                LaunchItem(
                    path: entry.path, scope: entry.scope, definition: entry.definition,
                    owner: owners.owner(of: entry.definition), loadState: loadState,
                    isDisabled: override ?? entry.definition.disabledInPlist))
        }
        inventory.bundled = bundledBackgroundItems()
        return inventory
    }

    /// `launchctl print system/<label>`: 0 = loaded, 113 = no such service, anything else unknown.
    func daemonState(_ label: String) -> LoadState {
        guard let arguments = try? LaunchctlCommand.printSystem(label: label),
            let output = try? runner.run(LaunchctlCommand.executable, arguments)
        else { return .unknown }
        switch output.status {
        case 0: return .loaded(pid: nil)
        case 113: return .notLoaded
        default: return .unknown
        }
    }

    /// Apps that carry login items or launchd jobs inside their bundle (`SMAppService`).
    func bundledBackgroundItems() -> [BundledBackgroundItem] {
        installedApps.compactMap { app in
            var items: [String] = []
            let library = (app.path as NSString).appendingPathComponent("Contents/Library")
            for (folder, suffix) in [("LoginItems", ".app"), ("LaunchAgents", ".plist"), ("LaunchDaemons", ".plist")] {
                let names =
                    (try? FileManager.default.contentsOfDirectory(
                        atPath: (library as NSString).appendingPathComponent(folder))) ?? []
                items += names.filter { $0.hasSuffix(suffix) }.sorted()
            }
            return items.isEmpty ? nil : BundledBackgroundItem(appName: app.name, bundlePath: app.path, items: items)
        }
    }

    private func run(_ arguments: [String]) -> CommandOutput? {
        guard let output = try? runner.run(LaunchctlCommand.executable, arguments), output.status == 0 else {
            return nil
        }
        return output
    }

    // MARK: Actions (user agents only)

    /// Stops the agent now and tells launchd not to load it again. Reversible with `enable`.
    @discardableResult
    public func disable(_ item: LaunchItem) throws -> LaunchItemActionResult {
        try checkActionable(item)
        // Not loaded is fine: the point is that it won't run.
        _ = try? runner.run(LaunchctlCommand.executable, LaunchctlCommand.bootout(uid: uid, label: item.label))
        let output = try runChecked(LaunchctlCommand.disable(uid: uid, label: item.label))
        guard output.status == 0 else { throw LoginItemsError.launchctlFailed(Self.message(output)) }
        return .done
    }

    /// Clears the disabled override and loads the agent again.
    @discardableResult
    public func enable(_ item: LaunchItem) throws -> LaunchItemActionResult {
        try checkActionable(item)
        let output = try runChecked(LaunchctlCommand.enable(uid: uid, label: item.label))
        guard output.status == 0 else { throw LoginItemsError.launchctlFailed(Self.message(output)) }
        let bootstrap = try? runner.run(
            LaunchctlCommand.executable, LaunchctlCommand.bootstrap(uid: uid, plistPath: item.path))
        if bootstrap?.status == 0 { return .done }
        return .doneWithNote("Enabled. It will start the next time you log in.")
    }

    /// Stops the agent and moves its plist into a quarantine session (restorable from History).
    @discardableResult
    public func remove(_ item: LaunchItem, now: Date = .now) throws -> SessionManifest {
        try checkActionable(item)
        _ = try? runner.run(LaunchctlCommand.executable, LaunchctlCommand.bootout(uid: uid, label: item.label))
        do {
            return try quarantine.quarantine(plistPath: item.path, now: now)
        } catch let error as LaunchAgentQuarantineError {
            throw LoginItemsError.quarantineFailed(error.description)
        } catch {
            throw LoginItemsError.quarantineFailed(error.localizedDescription)
        }
    }

    func checkActionable(_ item: LaunchItem) throws {
        guard item.scope.isActionable else { throw LoginItemsError.readOnly(item.label) }
        guard LaunchctlCommand.isValidLabel(item.label) else { throw LoginItemsError.invalidLabel(item.label) }
        let resolvedRoot = realPath(roots.userAgents) ?? roots.userAgents
        let parent = (item.path as NSString).deletingLastPathComponent
        guard item.path.utf8.first == 0x2F, !hasNonCanonicalComponent(item.path),
            canonicalPathKey(realPath(parent) ?? parent) == canonicalPathKey(resolvedRoot)
        else { throw LoginItemsError.notActionable(item.path) }
    }

    private func runChecked(_ arguments: [String]) throws -> CommandOutput {
        do {
            return try runner.run(LaunchctlCommand.executable, arguments)
        } catch {
            throw LoginItemsError.launchctlFailed("\(error)")
        }
    }

    static func message(_ output: CommandOutput) -> String {
        let text = (output.stderrText + output.stdoutText).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "exit status \(output.status)" : text
    }
}
