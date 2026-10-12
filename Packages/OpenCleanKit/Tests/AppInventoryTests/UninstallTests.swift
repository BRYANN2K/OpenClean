import Foundation
import Quarantine
import RuleKit
import ScanEngine
import TestSupport
import Testing

@testable import AppInventory

struct UninstallExemptionTests {
    func authorize(
        _ path: String, id: String = "com.example.a", home: TempDirectory, folders: [String]? = nil,
        protectedPaths: [String] = []
    ) -> Result<UninstallBundleExemption, UninstallRefusal> {
        UninstallBundleExemption.authorize(
            bundlePath: path, bundleID: id, allowedFolders: folders ?? [home.path + "/Applications"],
            denyList: DenyList(home: home.path), protectedBundleIDs: [InstalledApp.openCleanBundleID],
            protectedPaths: protectedPaths)
    }

    @Test func exemptionCoversOnlyTheRequestedBundle() throws {
        let home = try TempDirectory()
        let a = try FakeApps.make(home, "Applications/A.app", id: "com.example.a")
        let b = try FakeApps.make(home, "Applications/B.app", id: "com.example.b")
        let exemption = try authorize(a, home: home).get()
        let denyList = DenyList(home: home.path)
        let rule = UninstallService.rule(id: UninstallService.appRuleID, bundleID: "com.example.a")
        let exempt = PreDeleteChecker(
            denyList: denyList, processChecker: FakeProcessChecker(), openPaths: [], exemption: exemption)
        let plain = PreDeleteChecker(denyList: denyList, processChecker: FakeProcessChecker(), openPaths: [])

        func check(_ checker: PreDeleteChecker, _ path: String) throws -> SkipReason? {
            checker.check(try #require(ScanItem.snapshot(of: path, ruleID: rule.id)), rule: rule)
        }
        #expect(try check(exempt, a) == nil)
        #expect(try check(plain, a) == .protected("application bundle \(a)"))
        #expect(try check(exempt, b) == .protected("application bundle \(b)"))
        #expect(try check(exempt, a + "/Contents") == .protected("application bundle \(a)"))
        #expect(try check(exempt, a + "/Contents/Info.plist") == .protected("application bundle \(a)"))
        // Same location on a case-insensitive volume.
        #expect(exemption.permits(a.uppercased(), deniedFor: "application bundle \(a)"))
        #expect(!exemption.permits(a, deniedFor: "inside protected location /System"))
        #expect(!exemption.permits(home.path, deniedFor: "application bundle \(a)"))
    }

    @Test func otherDenyListRulesStayEnforced() throws {
        let home = try TempDirectory()
        let inDocuments = try FakeApps.make(home, "Documents/Apps/X.app", id: "com.example.x")
        let result = authorize(inDocuments, home: home, folders: [home.path + "/Documents/Apps"])
        #expect(result == .failure(.protected("inside protected location \(home.path)/Documents")))
    }

    @Test func refusesUnsafeRequests() throws {
        let home = try TempDirectory()
        let a = try FakeApps.make(home, "Applications/A.app", id: "com.example.a")
        let nested = try FakeApps.make(home, "Applications/Sub/N.app", id: "com.example.n")
        let plain = try home.directory("Applications/Folder")
        try home.symlink("Applications/Link.app", to: a)
        try home.symlink("AppsLink", to: home.path + "/Applications")

        #expect(authorize(a, id: "com.apple.Safari", home: home) == .failure(.appleApp))
        #expect(authorize(a, id: InstalledApp.openCleanBundleID, home: home) == .failure(.openClean))
        #expect(authorize(a, home: home, protectedPaths: [a]) == .failure(.openClean))
        #expect(authorize(a, id: "", home: home) == .failure(.invalidBundleID))
        #expect(authorize(a, id: "a/b", home: home) == .failure(.invalidBundleID))
        #expect(authorize(nested, home: home) == .failure(.outsideApplicationFolders))
        #expect(authorize(a, home: home, folders: [home.path + "/Elsewhere"]) == .failure(.outsideApplicationFolders))
        #expect(authorize(plain, home: home) == .failure(.notAnAppBundle))
        #expect(authorize(home.path + "/Applications/Link.app", home: home) == .failure(.notCanonical))
        #expect(authorize(home.path + "/AppsLink/A.app", home: home) == .failure(.notCanonical))
        #expect(authorize(home.path + "/Applications/../Applications/A.app", home: home) == .failure(.notCanonical))
        #expect(authorize(home.path + "/Applications/Gone.app", home: home) == .failure(.missing))
        #expect(authorize("/System/Applications/Calculator.app", home: home) == .failure(.appleApp))
    }

    @Test func refusesAppsTheUserCannotMove() throws {
        let home = try TempDirectory()
        let a = try FakeApps.make(home, "Applications/A.app", id: "com.example.a")
        try setPermissions(home.path + "/Applications", 0o555)
        defer { try? setPermissions(home.path + "/Applications", 0o755) }
        #expect(authorize(a, home: home) == .failure(.notWritable))
    }
}

struct UninstallServiceTests {
    struct Fixture {
        let home: TempDirectory
        let app: String
        let leftovers: [String]
        let store: QuarantineStore

        init() throws {
            home = try TempDirectory()
            app = try FakeApps.make(home, "Applications/Foo.app", id: "com.example.foo", bytes: 8_192)
            leftovers = [
                try home.directory("Library/Application Support/com.example.foo"),
                try home.file("Library/Preferences/com.example.foo.plist", bytes: 100),
            ]
            try home.file("Library/Application Support/com.example.foo/db", bytes: 2_048)
            store = QuarantineStore(
                root: home.url.appendingPathComponent("Library/Application Support/OpenClean/Quarantine"))
        }

        func service(running: Set<String> = []) -> UninstallService {
            UninstallService(
                store: store, denyList: DenyList(home: home.path), processChecker: FakeProcessChecker(running: running),
                admin: FakeAdminExecutor(), trash: { _ in nil })
        }

        func request(bundle: ScanItem? = nil, leftovers extra: [String]? = nil) throws -> UninstallRequest {
            UninstallRequest(
                bundle: try bundle ?? #require(ScanItem.snapshot(of: app, ruleID: UninstallService.appRuleID)),
                bundleID: "com.example.foo",
                leftovers: try (extra ?? leftovers).map {
                    try #require(ScanItem.snapshot(of: $0, ruleID: UninstallService.leftoverRuleID))
                })
        }

        func run(_ request: UninstallRequest, running: Set<String> = [], openPaths: Set<String>? = [])
            throws -> UninstallOutcome
        {
            try service(running: running).uninstall(
                request, allowedFolders: [home.path + "/Applications"],
                protectedBundleIDs: [InstalledApp.openCleanBundleID], protectedPaths: [], openPaths: openPaths)
        }

        var everythingInPlace: Bool {
            ([app] + leftovers).allSatisfy { FileStat.of($0) != nil }
        }
    }

    @Test func movesAppAndLeftoversToQuarantineAndRestoresThem() throws {
        let fixture = try Fixture()
        let outcome = try fixture.run(try fixture.request())
        guard case .finished(let report) = outcome else {
            Issue.record("expected a finished uninstall, got \(outcome)")
            return
        }
        #expect(report.manifest.entries.map(\.outcome) == [.quarantined, .quarantined, .quarantined])
        #expect(report.manifest.entries.map(\.ruleID) == ["uninstall.app", "uninstall.leftover", "uninstall.leftover"])
        #expect(report.manifest.entries.first?.originalPath == fixture.app)
        #expect(report.quarantinedBytes >= 8_192 + 2_048)
        #expect(([fixture.app] + fixture.leftovers).allSatisfy { FileStat.of($0) == nil })
        for entry in report.manifest.entries {
            #expect(pathIsWithin(try #require(entry.storedPath), fixture.store.itemsDirectory(report.manifest.id).path))
        }

        let restore = try RestoreService(store: fixture.store, trash: { _ in nil })
            .restore(sessionID: report.manifest.id, onConflict: .skip)
        #expect(restore.skipped.isEmpty)
        #expect(fixture.everythingInPlace)
        #expect(FileManager.default.fileExists(atPath: fixture.app + "/Contents/Info.plist"))
        #expect(FileManager.default.fileExists(atPath: fixture.leftovers[0] + "/db"))
    }

    @Test func refusesRunningAppAndMovesNothing() throws {
        let fixture = try Fixture()
        let outcome = try fixture.run(try fixture.request(), running: ["com.example.foo"])
        guard case .refused(let refusal) = outcome else {
            Issue.record("expected a refusal")
            return
        }
        #expect(refusal == .skipped(.appRunning("com.example.foo")))
        #expect(fixture.everythingInPlace)
        #expect(fixture.store.listSessions().isEmpty)
    }

    @Test func refusesAppChangedSinceInventory() throws {
        let fixture = try Fixture()
        let stale = try #require(ScanItem.snapshot(of: fixture.app, ruleID: UninstallService.appRuleID))
        // Replace the bundle with a different one at the same path.
        try FileManager.default.moveItem(atPath: fixture.app, toPath: fixture.home.path + "/Old.app")
        try FakeApps.make(fixture.home, "Applications/Foo.app", id: "com.example.foo")
        let outcome = try fixture.run(try fixture.request(bundle: stale))
        guard case .refused(let refusal) = outcome else {
            Issue.record("expected a refusal")
            return
        }
        #expect(refusal == .skipped(.changedSinceScan))
        #expect(fixture.store.listSessions().isEmpty)
        #expect(fixture.leftovers.allSatisfy { FileStat.of($0) != nil })
    }

    @Test func refusesAppInUseOrWhenOpenFilesAreUnknown() throws {
        let fixture = try Fixture()
        let inUse = try fixture.run(try fixture.request(), openPaths: [fixture.app + "/Contents/MacOS/app"])
        guard case .refused(.skipped(.inUse)) = inUse else {
            Issue.record("expected in-use refusal, got \(inUse)")
            return
        }
        let unknown = try fixture.run(try fixture.request(), openPaths: nil)
        guard case .refused(.skipped(.openFilesUnknown)) = unknown else {
            Issue.record("expected open-files-unknown refusal, got \(unknown)")
            return
        }
        #expect(fixture.everythingInPlace)
        #expect(fixture.store.listSessions().isEmpty)
    }

    @Test func refusesLeftoversOutsideTheLibrary() throws {
        let fixture = try Fixture()
        let outside = try fixture.home.file("Downloads/thing.zip")
        let outcome = try fixture.run(try fixture.request(leftovers: fixture.leftovers + [outside]))
        guard case .refused(.leftoverOutsideLibrary(let path)) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(path == outside)
        #expect(fixture.everythingInPlace)
    }

    @Test func denyListedLeftoversAreSkippedNotMoved() throws {
        let fixture = try Fixture()
        let keychain = try fixture.home.file("Library/Keychains/login.keychain-db")
        let outcome = try fixture.run(try fixture.request(leftovers: [keychain]))
        guard case .finished(let report) = outcome else {
            Issue.record("expected a finished uninstall, got \(outcome)")
            return
        }
        #expect(report.manifest.entries.map(\.outcome) == [.quarantined, .skipped])
        #expect(FileStat.of(keychain) != nil)
    }

    @Test func reportOnlyLeftoversAreRefused() throws {
        let fixture = try Fixture()
        let snapshot = try #require(ScanItem.snapshot(of: fixture.leftovers[1], ruleID: "x"))
        let reportOnly = ScanItem(
            path: snapshot.path, ruleID: snapshot.ruleID, size: snapshot.size, device: snapshot.device,
            inode: snapshot.inode, modificationDate: snapshot.modificationDate, ownerUID: snapshot.ownerUID,
            reportOnly: true)
        let request = UninstallRequest(
            bundle: try #require(ScanItem.snapshot(of: fixture.app, ruleID: "a")), bundleID: "com.example.foo",
            leftovers: [reportOnly])
        guard case .refused(.leftoverOutsideLibrary) = try fixture.run(request) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(fixture.everythingInPlace)
    }
}

/// Uninstalling an app the user can't move (`requiresAdministrator`). The fake executor never prompts;
/// with `runForReal` it runs the rendered `mv && chown` text as the current user against temp folders.
struct AdminUninstallServiceTests {
    struct Fixture {
        let home: TempDirectory
        let applications: String
        let app: String
        let leftovers: [String]
        let store: QuarantineStore

        init() throws {
            home = try TempDirectory()
            applications = home.path + "/Applications"
            app = try FakeApps.make(home, "Applications/Foo.app", id: "com.example.foo", bytes: 8_192)
            leftovers = [
                try home.directory("Library/Application Support/com.example.foo"),
                try home.file("Library/Preferences/com.example.foo.plist", bytes: 100),
            ]
            try home.file("Library/Application Support/com.example.foo/db", bytes: 2_048)
            store = QuarantineStore(
                root: home.url.appendingPathComponent("Library/Application Support/OpenClean/Quarantine"))
        }

        func request(bundle: ScanItem? = nil, requiresAdministrator: Bool = true) throws -> UninstallRequest {
            UninstallRequest(
                bundle: try bundle ?? #require(ScanItem.snapshot(of: app, ruleID: UninstallService.appRuleID)),
                bundleID: "com.example.foo",
                leftovers: try leftovers.map {
                    try #require(ScanItem.snapshot(of: $0, ruleID: UninstallService.leftoverRuleID))
                },
                requiresAdministrator: requiresAdministrator)
        }

        func run(
            _ request: UninstallRequest, executor: FakeAdminExecutor?, running: Set<String> = [],
            openPaths: Set<String>? = []
        ) throws -> UninstallOutcome {
            try UninstallService(
                store: store, denyList: DenyList(home: home.path),
                processChecker: FakeProcessChecker(running: running), admin: FakeAdminExecutor(),
                bundleAdmin: executor, trash: { _ in nil }
            ).uninstall(
                request, allowedFolders: [applications], protectedBundleIDs: [InstalledApp.openCleanBundleID],
                protectedPaths: [], openPaths: openPaths)
        }

        var everythingInPlace: Bool { ([app] + leftovers).allSatisfy { FileStat.of($0) != nil } }

        /// Makes Applications read-only, like `/Applications` is for a root-owned bundle's parent.
        func lockApplications() throws { try setPermissions(applications, 0o555) }
        func unlockApplications() { try? setPermissions(applications, 0o755) }
    }

    @Test func movesBundleWithOnePromptThenLeftoversAndRestoresAsUser() throws {
        let fixture = try Fixture()
        try fixture.lockApplications()
        defer { fixture.unlockApplications() }
        let store = fixture.store
        let leftovers = fixture.leftovers
        let applications = fixture.applications
        let seenAtPrompt = Box<SessionManifest>()
        let executor = FakeAdminExecutor(runForReal: true) { _ in
            // Intent is on disk before the prompt, and nothing has moved yet.
            if case .ok(let manifest) = store.listSessions().first { seenAtPrompt.value = manifest }
            #expect(leftovers.allSatisfy { FileStat.of($0) != nil })
            try? setPermissions(applications, 0o755)  // stands in for root
        }

        let outcome = try fixture.run(try fixture.request(), executor: executor)
        guard case .finished(let report) = outcome else {
            Issue.record("expected a finished uninstall, got \(outcome)")
            return
        }
        let manifest = report.manifest
        #expect(seenAtPrompt.value?.entries.map(\.outcome) == [.pending, .pending, .pending])
        #expect(seenAtPrompt.value?.entries.first?.storedPath == manifest.entries.first?.storedPath)
        #expect(manifest.entries.map(\.outcome) == [.quarantined, .quarantined, .quarantined])
        #expect(manifest.entries.allSatisfy { $0.reason == nil })
        #expect(try fixture.store.read(id: manifest.id) == manifest)

        #expect(executor.bundleMoves.count == 1)
        let move = try #require(executor.bundleMoves.first)
        let stored = try #require(manifest.entries.first?.storedPath)
        #expect(move.source == fixture.app)
        #expect(move.destination == stored)
        #expect(pathIsWithin(stored, fixture.store.itemsDirectory(manifest.id).path))
        #expect(([fixture.app] + fixture.leftovers).allSatisfy { FileStat.of($0) == nil })
        #expect(FileStat.of(stored)?.ownerUID == getuid())

        let restore = try RestoreService(store: fixture.store, trash: { _ in nil })
            .restore(sessionID: manifest.id, onConflict: .skip)
        #expect(restore.skipped.isEmpty)
        #expect(fixture.everythingInPlace)
        #expect(FileStat.of(fixture.app)?.ownerUID == getuid())
        #expect(FileManager.default.fileExists(atPath: fixture.app + "/Contents/Info.plist"))
    }

    @Test func cancelledPromptMovesNothing() throws {
        let fixture = try Fixture()
        let executor = FakeAdminExecutor(outcome: .cancelled)
        guard case .finished(let report) = try fixture.run(try fixture.request(), executor: executor) else {
            Issue.record("expected a finished session")
            return
        }
        let entries = report.manifest.entries
        #expect(executor.bundleMoves.count == 1)
        #expect(entries.map(\.outcome) == [.failed, .skipped, .skipped])
        #expect(entries.first?.reason == SkipReason.adminCancelled.description)
        #expect(entries.dropFirst().allSatisfy { $0.reason == SkipReason.appNotMoved.description })
        #expect(entries.allSatisfy { $0.storedPath == nil })
        #expect(report.manifest.restorableEntries.isEmpty)
        #expect(fixture.everythingInPlace)
    }

    @Test func failedPromptMovesNothing() throws {
        let fixture = try Fixture()
        let executor = FakeAdminExecutor(outcome: .failed("mv: Operation not permitted"))
        guard case .finished(let report) = try fixture.run(try fixture.request(), executor: executor) else {
            Issue.record("expected a finished session")
            return
        }
        #expect(report.manifest.entries.map(\.outcome) == [.failed, .skipped, .skipped])
        #expect(report.manifest.entries.first?.reason == "mv: Operation not permitted")
        #expect(fixture.everythingInPlace)
    }

    @Test func reportsAMoveThatHappenedDespiteAFailedStatus() throws {
        let fixture = try Fixture()
        // The bundle was staged and handed over, but the script still reported an error: the final move
        // into quarantine happens anyway and the entry must stay restorable.
        let executor = FakeAdminExecutor(outcome: .failed("chown: Operation not permitted")) { move in
            try? FileManager.default.createDirectory(
                atPath: move.stagingDirectory, withIntermediateDirectories: false)
            try? FileManager.default.moveItem(atPath: move.source, toPath: move.stagingBundle)
        }
        guard case .finished(let report) = try fixture.run(try fixture.request(), executor: executor) else {
            Issue.record("expected a finished session")
            return
        }
        let first = try #require(report.manifest.entries.first)
        #expect(first.outcome == .quarantined)
        #expect(first.reason == "moved, but: chown: Operation not permitted")
        #expect(FileStat.of(try #require(first.storedPath)) != nil)
        #expect(report.manifest.entries.dropFirst().allSatisfy { $0.outcome == .quarantined })
    }

    /// Something planted at the quarantine destination while the prompt is open is never entered or
    /// replaced; the app stays in the staging folder, the entry fails with its location, leftovers stay.
    @Test func aDestinationPlantedDuringThePromptFailsAndSaysWhereTheAppIs() throws {
        let fixture = try Fixture()
        let staging = Box<String>()
        let planted = Box<String>()
        let executor = FakeAdminExecutor(runForReal: true) { move in
            staging.value = move.stagingDirectory
            planted.value = move.destination
            try? FileManager.default.createDirectory(atPath: move.destination, withIntermediateDirectories: false)
            FileManager.default.createFile(atPath: move.destination + "/marker", contents: Data("x".utf8))
        }
        defer {
            if let staging = staging.value { try? FileManager.default.removeItem(atPath: staging) }
        }
        guard case .finished(let report) = try fixture.run(try fixture.request(), executor: executor) else {
            Issue.record("expected a finished session")
            return
        }
        let entries = report.manifest.entries
        let stagingPath = try #require(staging.value)
        #expect(entries.map(\.outcome) == [.failed, .skipped, .skipped])
        #expect(entries.first?.reason?.contains(stagingPath + "/Foo.app") == true)
        #expect(entries.dropFirst().allSatisfy { $0.reason == SkipReason.appNotMoved.description })
        #expect(try FileManager.default.contentsOfDirectory(atPath: try #require(planted.value)) == ["marker"])
        #expect(FileStat.of(stagingPath + "/Foo.app/Contents/Info.plist") != nil)
        #expect(fixture.leftovers.allSatisfy { FileStat.of($0) != nil })
    }

    @Test func refusesRunningOrChangedAppsWithoutPrompting() throws {
        let fixture = try Fixture()
        let executor = FakeAdminExecutor(runForReal: true)
        let running = try fixture.run(try fixture.request(), executor: executor, running: ["com.example.foo"])
        guard case .refused(.skipped(.appRunning("com.example.foo"))) = running else {
            Issue.record("expected a running refusal, got \(running)")
            return
        }
        let inUse = try fixture.run(try fixture.request(), executor: executor, openPaths: [fixture.app])
        guard case .refused(.skipped(.inUse)) = inUse else {
            Issue.record("expected an in-use refusal, got \(inUse)")
            return
        }

        let stale = try #require(ScanItem.snapshot(of: fixture.app, ruleID: UninstallService.appRuleID))
        try FileManager.default.moveItem(atPath: fixture.app, toPath: fixture.home.path + "/Old.app")
        try FakeApps.make(fixture.home, "Applications/Foo.app", id: "com.example.foo")
        let changed = try fixture.run(try fixture.request(bundle: stale), executor: executor)
        guard case .refused(.skipped(.changedSinceScan)) = changed else {
            Issue.record("expected a changed refusal, got \(changed)")
            return
        }
        #expect(executor.bundleMoves.isEmpty)
        #expect(fixture.store.listSessions().isEmpty)
        #expect(fixture.everythingInPlace)
    }

    @Test func refusesWithoutAnAdministratorExecutor() throws {
        let fixture = try Fixture()
        guard case .refused(.needsAdministrator) = try fixture.run(try fixture.request(), executor: nil) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(fixture.everythingInPlace)
        #expect(fixture.store.listSessions().isEmpty)
    }

    @Test func ordinaryRequestsNeverUseTheAdministratorPath() throws {
        let fixture = try Fixture()
        let executor = FakeAdminExecutor()
        guard
            case .finished(let report) = try fixture.run(
                try fixture.request(requiresAdministrator: false), executor: executor)
        else {
            Issue.record("expected a finished uninstall")
            return
        }
        #expect(report.manifest.entries.map(\.outcome) == [.quarantined, .quarantined, .quarantined])
        #expect(executor.bundleMoves.isEmpty)
        #expect(executor.commands.isEmpty)
    }

    @Test func administratorExemptionKeepsEveryOtherCheck() throws {
        let home = try TempDirectory()
        let a = try FakeApps.make(home, "Applications/A.app", id: "com.example.a")
        try setPermissions(home.path + "/Applications", 0o555)
        defer { try? setPermissions(home.path + "/Applications", 0o755) }
        func authorize(_ id: String, folders: [String]? = nil) -> Result<UninstallBundleExemption, UninstallRefusal> {
            UninstallBundleExemption.authorize(
                bundlePath: a, bundleID: id, allowedFolders: folders ?? [home.path + "/Applications"],
                denyList: DenyList(home: home.path), protectedBundleIDs: [InstalledApp.openCleanBundleID],
                protectedPaths: [], administrator: true)
        }
        #expect((try? authorize("com.example.a").get()) != nil)
        #expect(authorize("com.apple.Safari") == .failure(.appleApp))
        #expect(authorize(InstalledApp.openCleanBundleID) == .failure(.openClean))
        #expect(authorize("com.example.a", folders: [home.path + "/Elsewhere"]) == .failure(.outsideApplicationFolders))
    }
}

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
