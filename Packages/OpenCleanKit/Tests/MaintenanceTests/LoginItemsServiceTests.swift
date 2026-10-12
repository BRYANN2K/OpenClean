import Foundation
import Quarantine
import TestSupport
import Testing

@testable import Maintenance

/// A fake home with LaunchAgents folders. Nothing here touches the real home or launchd.
struct AgentsFixture {
    let dir: TempDirectory
    let roots: LaunchItemRoots
    let runner = FakeCommandRunner()
    let uid = getuid()
    let store: QuarantineStore

    init() throws {
        dir = try TempDirectory()
        roots = LaunchItemRoots(
            userAgents: try dir.directory("home/Library/LaunchAgents"),
            systemAgents: try dir.directory("Library/LaunchAgents"),
            systemDaemons: try dir.directory("Library/LaunchDaemons"))
        store = QuarantineStore(
            root: dir.url.appendingPathComponent("home/Library/Application Support/OpenClean/Quarantine"))
    }

    @discardableResult
    func plist(_ directory: String, _ name: String, _ object: [String: Any]) throws -> String {
        let path = (directory as NSString).appendingPathComponent(name)
        try plistData(object).write(to: URL(fileURLWithPath: path))
        return path
    }

    func service(apps: [InstalledApp] = []) -> LoginItemsService {
        LoginItemsService(roots: roots, uid: uid, runner: runner, installedApps: apps, quarantineStore: store)
    }

    func launchctl(_ arguments: String, status: Int32 = 0, stdout: String = "", stderr: String = "") {
        runner.respond("/bin/launchctl " + arguments, status: status, stdout: stdout, stderr: stderr)
    }
}

struct LoginItemsInventoryTests {
    @Test func listsAllScopesWithLoadAndDisabledState() throws {
        let fixture = try AgentsFixture()
        try fixture.plist(
            fixture.roots.userAgents, "com.example.sync.plist",
            ["Label": "com.example.sync", "ProgramArguments": ["/Applications/Sync.app/Contents/MacOS/agent"]])
        try fixture.plist(
            fixture.roots.userAgents, "com.example.off.plist", ["Label": "com.example.off", "Disabled": true])
        try fixture.plist(fixture.roots.userAgents, "broken.plist", ["Program": "/x"])
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: fixture.roots.userAgents + "/garbage.plist"))
        try Data().write(to: URL(fileURLWithPath: fixture.roots.userAgents + "/.hidden.plist"))
        try Data().write(to: URL(fileURLWithPath: fixture.roots.userAgents + "/notes.txt"))
        try fixture.plist(fixture.roots.systemAgents, "org.shared.agent.plist", ["Label": "org.shared.agent"])
        try fixture.plist(fixture.roots.systemDaemons, "us.zoom.ZoomDaemon.plist", ["Label": "us.zoom.ZoomDaemon"])
        try fixture.plist(fixture.roots.systemDaemons, "com.gone.daemon.plist", ["Label": "com.gone.daemon"])

        fixture.launchctl("list", stdout: "PID\tStatus\tLabel\n321\t0\tcom.example.sync\n-\t0\torg.shared.agent\n")
        fixture.launchctl(
            "print-disabled gui/\(fixture.uid)",
            stdout: "disabled services = {\n\t\"com.example.off\" => enabled\n\t\"com.example.sync\" => disabled\n}\n")
        fixture.launchctl("print-disabled system", stdout: "")
        fixture.launchctl("print system/us.zoom.ZoomDaemon", status: 0)
        fixture.launchctl("print system/com.gone.daemon", status: 113)

        let inventory = fixture.service().inventory()
        #expect(inventory.launchctlAvailable)
        #expect(inventory.items.count == 5)
        #expect(
            Set(inventory.unreadable.map { ($0.path as NSString).lastPathComponent }) == [
                "broken.plist", "garbage.plist",
            ])

        let sync = try #require(inventory.items.first { $0.label == "com.example.sync" })
        #expect(sync.scope == .user)
        #expect(sync.loadState == .loaded(pid: 321))
        #expect(sync.isDisabled, "launchd's override wins over the plist")
        #expect(sync.owner?.appName == "Sync")

        let off = try #require(inventory.items.first { $0.label == "com.example.off" })
        #expect(off.loadState == .notLoaded)
        #expect(!off.isDisabled, "override says enabled even though the plist says Disabled")

        let shared = try #require(inventory.items.first { $0.label == "org.shared.agent" })
        #expect(shared.scope == .systemAgent)
        #expect(shared.loadState.isLoaded)

        #expect(inventory.items.first { $0.label == "us.zoom.ZoomDaemon" }?.loadState == .loaded(pid: nil))
        #expect(inventory.items.first { $0.label == "com.gone.daemon" }?.loadState == .notLoaded)
        #expect(inventory.items(in: .systemDaemon).count == 2)
    }

    @Test func launchctlFailureMeansUnknownNotUnloaded() throws {
        let fixture = try AgentsFixture()
        try fixture.plist(fixture.roots.userAgents, "a.plist", ["Label": "a", "Disabled": true])
        // Nothing stubbed: every launchctl call exits 127.
        let inventory = fixture.service().inventory()
        #expect(!inventory.launchctlAvailable)
        #expect(inventory.items.first?.loadState == .unknown)
        #expect(inventory.items.first?.isDisabled == true, "falls back to the plist's Disabled key")
    }

    @Test func findsBackgroundItemsBundledInsideApps() throws {
        let fixture = try AgentsFixture()
        let app = try fixture.dir.directory("Applications/Mailer.app")
        try fixture.dir.directory("Applications/Mailer.app/Contents/Library/LoginItems/Mailer Helper.app")
        try fixture.dir.file("Applications/Mailer.app/Contents/Library/LaunchAgents/com.mailer.agent.plist")
        let plain = try fixture.dir.directory("Applications/Plain.app")
        let inventory = fixture.service(apps: [
            InstalledApp(name: "Mailer", bundleID: "com.mailer", path: app),
            InstalledApp(name: "Plain", bundleID: "com.plain", path: plain),
        ]).inventory()
        #expect(
            inventory.bundled == [
                BundledBackgroundItem(
                    appName: "Mailer", bundlePath: app, items: ["Mailer Helper.app", "com.mailer.agent.plist"])
            ])
    }
}

struct LoginItemsActionTests {
    func userItem(_ fixture: AgentsFixture, label: String = "com.example.agent") throws -> LaunchItem {
        let path = try fixture.plist(
            fixture.roots.userAgents, "\(label).plist", ["Label": label, "Program": "/bin/true"])
        return LaunchItem(
            path: path, scope: .user, definition: LaunchItemDefinition(label: label, program: "/bin/true"),
            owner: nil, loadState: .loaded(pid: 5), isDisabled: false)
    }

    @Test func disableBootsOutThenDisables() throws {
        let fixture = try AgentsFixture()
        let item = try userItem(fixture)
        fixture.launchctl("bootout gui/\(fixture.uid)/com.example.agent", status: 3, stderr: "No such process")
        fixture.launchctl("disable gui/\(fixture.uid)/com.example.agent")
        #expect(try fixture.service().disable(item) == .done)
        #expect(
            fixture.runner.calls == [
                ["/bin/launchctl", "bootout", "gui/\(fixture.uid)/com.example.agent"],
                ["/bin/launchctl", "disable", "gui/\(fixture.uid)/com.example.agent"],
            ])
    }

    @Test func disableFailsWhenLaunchctlDisableFails() throws {
        let fixture = try AgentsFixture()
        let item = try userItem(fixture)
        fixture.launchctl("disable gui/\(fixture.uid)/com.example.agent", status: 1, stderr: "nope")
        #expect(throws: LoginItemsError.launchctlFailed("nope")) { try fixture.service().disable(item) }
    }

    @Test func enableReportsWhenItCanOnlyStartAtNextLogin() throws {
        let fixture = try AgentsFixture()
        let item = try userItem(fixture)
        fixture.launchctl("enable gui/\(fixture.uid)/com.example.agent")
        #expect(try fixture.service().enable(item) == .doneWithNote("Enabled. It will start the next time you log in."))
        fixture.launchctl("bootstrap gui/\(fixture.uid) \(item.path)")
        #expect(try fixture.service().enable(item) == .done)
        #expect(fixture.runner.calls.last == ["/bin/launchctl", "bootstrap", "gui/\(fixture.uid)", item.path])
    }

    @Test func systemItemsAreReadOnlyAndNeverReachLaunchctl() throws {
        let fixture = try AgentsFixture()
        let path = try fixture.plist(fixture.roots.systemDaemons, "d.plist", ["Label": "d"])
        for scope in [LaunchItemScope.systemAgent, .systemDaemon] {
            let item = LaunchItem(
                path: path, scope: scope, definition: LaunchItemDefinition(label: "d", program: nil), owner: nil,
                loadState: .notLoaded, isDisabled: false)
            #expect(throws: LoginItemsError.readOnly("d")) { try fixture.service().disable(item) }
            #expect(throws: LoginItemsError.readOnly("d")) { try fixture.service().enable(item) }
            #expect(throws: LoginItemsError.readOnly("d")) { try fixture.service().remove(item) }
        }
        #expect(fixture.runner.calls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func userScopedItemOutsideTheUserFolderIsRefused() throws {
        let fixture = try AgentsFixture()
        let path = try fixture.plist(fixture.roots.systemAgents, "sneaky.plist", ["Label": "sneaky"])
        let item = LaunchItem(
            path: path, scope: .user, definition: LaunchItemDefinition(label: "sneaky", program: nil), owner: nil,
            loadState: .notLoaded, isDisabled: false)
        #expect(throws: LoginItemsError.notActionable(path)) { try fixture.service().remove(item) }
        #expect(fixture.runner.calls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func removeMovesThePlistToQuarantineAndRestoreBringsItBack() throws {
        let fixture = try AgentsFixture()
        let item = try userItem(fixture)
        let original = try Data(contentsOf: URL(fileURLWithPath: item.path))

        let manifest = try fixture.service().remove(item)
        #expect(fixture.runner.calls.first == ["/bin/launchctl", "bootout", "gui/\(fixture.uid)/com.example.agent"])
        #expect(!FileManager.default.fileExists(atPath: item.path))
        let entry = try #require(manifest.entries.first)
        #expect(entry.outcome == .quarantined)
        #expect(entry.ruleID == LaunchAgentQuarantine.ruleID)
        #expect(entry.originalPath == item.path)
        let stored = try #require(entry.storedPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: stored)) == original)
        #expect(try fixture.store.read(id: manifest.id) == manifest)

        let report = try RestoreService(store: fixture.store).restore(sessionID: manifest.id, onConflict: .skip)
        #expect(report.restored == [item.path])
        #expect(try Data(contentsOf: URL(fileURLWithPath: item.path)) == original)
    }

    @Test func symlinkedPlistIsNotQuarantined() throws {
        let fixture = try AgentsFixture()
        let target = try fixture.dir.file("elsewhere/real.plist", bytes: 10)
        let link = try fixture.dir.symlink("home/Library/LaunchAgents/link.plist", to: target)
        let item = LaunchItem(
            path: link, scope: .user, definition: LaunchItemDefinition(label: "link", program: nil), owner: nil,
            loadState: .notLoaded, isDisabled: false)
        #expect(throws: LoginItemsError.self) { try fixture.service().remove(item) }
        #expect(FileManager.default.fileExists(atPath: target))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == target)
    }

    /// A removal the quarantine would refuse must not stop the agent first.
    @Test func refusedRemovalNeverBootsTheAgentOut() throws {
        let fixture = try AgentsFixture()
        let target = try fixture.dir.file("elsewhere/real.plist", bytes: 10)
        let link = try fixture.dir.symlink("home/Library/LaunchAgents/link.plist", to: target)
        let symlinked = LaunchItem(
            path: link, scope: .user, definition: LaunchItemDefinition(label: "link", program: nil), owner: nil,
            loadState: .loaded(pid: 7), isDisabled: false)
        #expect(throws: LoginItemsError.quarantineFailed(LaunchAgentQuarantineError.notARegularFile(link).description))
        {
            try fixture.service().remove(symlinked)
        }
        let folder = try fixture.dir.directory("home/Library/LaunchAgents/folder.plist")
        let directory = LaunchItem(
            path: folder, scope: .user, definition: LaunchItemDefinition(label: "folder", program: nil), owner: nil,
            loadState: .loaded(pid: 8), isDisabled: false)
        #expect(throws: LoginItemsError.self) { try fixture.service().remove(directory) }
        #expect(fixture.runner.calls.isEmpty)
        #expect(fixture.store.listSessions().isEmpty)
    }
}
