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
