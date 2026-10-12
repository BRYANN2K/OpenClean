import Darwin
import Foundation
import RuleKit
import ScanEngine
import Testing
import TestSupport
@testable import Quarantine

struct RestoreAndPurgeTests {
    func quarantine(_ home: TempDirectory, _ paths: [String]) throws -> (QuarantineStore, RemovalReport) {
        let store = QuarantineStore(root: home.url.appendingPathComponent("Quarantine"))
        let checker = PreDeleteChecker(
            denyList: DenyList(home: home.path), processChecker: FakeProcessChecker(), openPaths: [])
        let rule = Rule(id: "r", name: "R", category: .user, explain: "x", paths: ["~/x"], safety: .review)
        let requests = try paths.map { RemovalRequest(item: try #require(ScanItem.snapshot(of: $0, ruleID: "r")), rule: rule) }
        let report = try Remover(store: store, checker: checker, admin: FakeAdminExecutor()).remove(requests)
        return (store, report)
    }

    func fakeTrash(_ home: TempDirectory) throws -> TrashOperation {
        let bin = try home.directory("FakeTrash")
        return { source in
            let destination = bin + "/" + UUID().uuidString
            try FileManager.default.moveItem(atPath: source, toPath: destination)
            return destination
        }
    }

    @Test func restoresBytesPermissionsAndXattrs() throws {
        let home = try TempDirectory()
        let path = try home.file("Downloads/report.bin", bytes: 3_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
        let value = Array("hello".utf8)
        #expect(setxattr(path, "com.openclean.test", value, value.count, 0, XATTR_NOFOLLOW) == 0)

        let (store, report) = try quarantine(home, [path])
        #expect(!FileManager.default.fileExists(atPath: path))
        let restored = try RestoreService(store: store).restore(sessionID: report.manifest.id, onConflict: .skip)

        #expect(restored.restored == [path])
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data(repeating: 0xAB, count: 3_000))
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(perms == 0o640)
        var buffer = [UInt8](repeating: 0, count: 16)
        let length = getxattr(path, "com.openclean.test", &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        #expect(Array(buffer.prefix(max(length, 0))) == value)
        #expect(try store.read(id: report.manifest.id).entries.first?.outcome == .restored)
    }

    @Test func restoresUnusualNames() throws {
        let home = try TempDirectory()
        let names = ["line\nbreak", "emoji 🧹.txt", #"quote'"s"#, "-dash", "spa ce"]
        let paths = try names.map { try home.file("odd/" + $0, bytes: 7) }
        let (store, report) = try quarantine(home, paths)
        let restored = try RestoreService(store: store).restore(sessionID: report.manifest.id, onConflict: .skip)
        #expect(Set(restored.restored) == Set(paths))
        for path in paths { #expect(FileManager.default.fileExists(atPath: path)) }
    }

    @Test func conflictPolicies() throws {
        let home = try TempDirectory()
        let path = try home.file("a/f.txt", bytes: 5)
        let (store, report) = try quarantine(home, [path])
        try home.file("a/f.txt", bytes: 1)

        let skipped = try RestoreService(store: store).restore(sessionID: report.manifest.id, onConflict: .skip)
        #expect(skipped.restored.isEmpty)
        #expect(skipped.skipped.first?.reason == "a file already exists at the original location")

        let both = try RestoreService(store: store).restore(sessionID: report.manifest.id, onConflict: .keepBoth)
        #expect(both.restored == [home.path + "/a/f (restored).txt"])
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func replaceMovesExistingFileToTrashFirst() throws {
        let home = try TempDirectory()
        let path = try home.file("a/f.txt", bytes: 5)
        let (store, report) = try quarantine(home, [path])
        try home.file("a/f.txt", bytes: 1)
        let service = RestoreService(store: store, trash: try fakeTrash(home))
        let result = try service.restore(sessionID: report.manifest.id, onConflict: .replace)
        #expect(result.restored == [path])
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).count == 5)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path + "/FakeTrash").count == 1)
    }

    @Test func restoresOnlySelectedPaths() throws {
        let home = try TempDirectory()
        let a = try home.file("a", bytes: 1)
        let b = try home.file("b", bytes: 1)
        let (store, report) = try quarantine(home, [a, b])
        let result = try RestoreService(store: store).restore(sessionID: report.manifest.id, paths: [b], onConflict: .skip)
        #expect(result.restored == [b])
        #expect(!FileManager.default.fileExists(atPath: a))
    }

    @Test func restoresPendingEntriesAfterCrash() throws {
        let home = try TempDirectory()
        let store = QuarantineStore(root: home.url.appendingPathComponent("Quarantine"))
        var session = try store.createSession()
        let stored = store.itemsDirectory(session.id).appendingPathComponent("0/f.txt").path
        try FileManager.default.createDirectory(
            atPath: (stored as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: stored))
        let original = home.path + "/Downloads/f.txt"
        session.entries = [
            ManifestEntry(
                id: 0, originalPath: original, storedPath: stored, size: 3, ruleID: "r",
                mode: .quarantine, outcome: .pending, reason: nil)
        ]
        try store.write(session)

        let result = try RestoreService(store: store).restore(sessionID: session.id, onConflict: .skip)
        #expect(result.restored == [original])
        #expect(try Data(contentsOf: URL(fileURLWithPath: original)) == Data([1, 2, 3]))
    }

    @Test func missingStoredCopyIsReported() throws {
        let home = try TempDirectory()
        let path = try home.file("a", bytes: 1)
        let (store, report) = try quarantine(home, [path])
        try FileManager.default.removeItem(atPath: try #require(report.manifest.entries.first?.storedPath))
        let result = try RestoreService(store: store).restore(sessionID: report.manifest.id, onConflict: .skip)
        #expect(result.skipped == [RestoreSkip(path: path, reason: "stored copy is missing")])
    }

    @Test func purgesOnlyExpiredSessions() throws {
        let home = try TempDirectory()
        let store = QuarantineStore(root: home.url.appendingPathComponent("Quarantine"))
        let now = Date()
        var old = try store.createSession(now: now.addingTimeInterval(-10 * 86_400))
        let oldStored = store.itemsDirectory(old.id).appendingPathComponent("0/x").path
        try FileManager.default.createDirectory(
            atPath: (oldStored as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data([1]).write(to: URL(fileURLWithPath: oldStored))
        old.entries = [
            ManifestEntry(
                id: 0, originalPath: "/x", storedPath: oldStored, size: 1, ruleID: "r", mode: .quarantine,
                outcome: .quarantined, reason: nil)
        ]
        try store.write(old)
        let recent = try store.createSession(now: now.addingTimeInterval(-86_400))

        let purged = Purger(store: store).purge(retentionDays: 7, now: now)

        #expect(purged == [old.id])
        #expect(!FileManager.default.fileExists(atPath: store.itemsDirectory(old.id).path))
        let reloaded = try store.read(id: old.id)
        #expect(reloaded.entries.first?.outcome == .purged)
        #expect(reloaded.purgedAt == now.wholeSeconds)
        #expect(FileManager.default.fileExists(atPath: store.itemsDirectory(recent.id).path))
        #expect(Purger(store: store).purge(retentionDays: 7, now: now).isEmpty)
    }

    @Test func purgesDamagedSessionsByFolderDate() throws {
        let home = try TempDirectory()
        let store = QuarantineStore(root: home.url.appendingPathComponent("Quarantine"))
        let folder = store.sessionDirectory("broken")
        try FileManager.default.createDirectory(at: store.itemsDirectory("broken"), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: folder.path)
        #expect(Purger(store: store).purge(retentionDays: 7) == ["broken"])
        #expect(!FileManager.default.fileExists(atPath: store.itemsDirectory("broken").path))
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func retentionIsClampedToOneThroughNinety() throws {
        let home = try TempDirectory()
        let store = QuarantineStore(root: home.url.appendingPathComponent("Quarantine"))
        let now = Date()
        let twoDays = try store.createSession(now: now.addingTimeInterval(-2 * 86_400))
        let halfDay = try store.createSession(now: now.addingTimeInterval(-12 * 3_600))
        #expect(Purger(store: store).purge(retentionDays: 0, now: now) == [twoDays.id])
        #expect(FileManager.default.fileExists(atPath: store.itemsDirectory(halfDay.id).path))
    }

    @Test func scheduleWritesLaunchAgentAndBootstrapsIt() throws {
        let home = try TempDirectory()
        let runner = FakeCommandRunner()
        let schedule = PurgeSchedule(home: home.path, runner: runner, uid: 501)
        runner.respond("/bin/launchctl bootstrap gui/501 \(schedule.plistURL.path)")

        try schedule.enable(executable: "/usr/local/bin/openclean")

        #expect(schedule.isEnabled)
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: schedule.plistURL), format: nil) as? [String: Any]
        #expect(plist?["Label"] as? String == "io.github.leoanimesh.openclean.purge")
        #expect(plist?["ProgramArguments"] as? [String] == ["/usr/local/bin/openclean", "purge"])
        #expect(runner.calls.contains(["/bin/launchctl", "bootstrap", "gui/501", schedule.plistURL.path]))

        try schedule.disable()
        #expect(!schedule.isEnabled)
        #expect(runner.calls.last == ["/bin/launchctl", "bootout", "gui/501/io.github.leoanimesh.openclean.purge"])
    }

    // MARK: fix round 1

    func rewriteManifest(_ store: QuarantineStore, _ id: String, _ change: (String) -> String) throws {
        let url = store.sessionDirectory(id).appendingPathComponent("manifest.json")
        let text = try String(contentsOf: url, encoding: .utf8)
        try change(text).write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func tamperedManifestIdIsDamagedAndNeverPurgedOutsideRoot() throws {
        let home = try TempDirectory()
        let store = QuarantineStore(root: home.url.appendingPathComponent("Quarantine"))
        let now = Date()
        let session = try store.createSession(now: now.addingTimeInterval(-10 * 86_400))
        let victim = try home.file("Victim/items/keep.txt", bytes: 3)
        try rewriteManifest(store, session.id) { $0.replacingOccurrences(of: session.id, with: "../Victim") }

        #expect(throws: QuarantineError.manifestMismatch(session.id)) { try store.read(id: session.id) }
        guard case .damaged = try #require(store.listSessions().first) else {
            Issue.record("expected damaged listing")
            return
        }
        _ = Purger(store: store).purge(retentionDays: 1, now: now)
        #expect(FileManager.default.fileExists(atPath: victim))
    }

    @Test func unsafeSessionIdsAreRejected() throws {
        let home = try TempDirectory()
        let store = QuarantineStore(root: home.url.appendingPathComponent("Quarantine"))
        for id in ["", ".", "..", "a/b", "../x"] {
            #expect(throws: QuarantineError.self) { try store.read(id: id) }
        }
    }

    func tamperedSession(
        _ home: TempDirectory, outcome: EntryOutcome, stored: String, original: String
    ) throws -> (QuarantineStore, String) {
        let store = QuarantineStore(root: home.url.appendingPathComponent("Quarantine"))
        var session = try store.createSession()
        session.entries = [
            ManifestEntry(
                id: 0, originalPath: original, storedPath: stored, size: 1, ruleID: "r", mode: .quarantine,
                outcome: outcome, reason: nil)
        ]
        try store.write(session)
        return (store, session.id)
    }

    @Test func restoreRejectsStoredPathOutsideItems() throws {
        let home = try TempDirectory()
        let secret = try home.file("Secret/data", bytes: 4)
        let original = home.path + "/Restored/data"
        let (store, id) = try tamperedSession(home, outcome: .quarantined, stored: secret, original: original)
        let result = try RestoreService(store: store).restore(sessionID: id, onConflict: .skip)
        #expect(result.restored.isEmpty)
        #expect(result.skipped.first?.reason == "manifest entry points outside quarantine")
        #expect(FileManager.default.fileExists(atPath: secret))
    }

    @Test func restoreRejectsNonCanonicalStoredAndBadOriginal() throws {
        let home = try TempDirectory()
        let secret = try home.file("Secret/data", bytes: 4)
        let store0 = QuarantineStore(root: home.url.appendingPathComponent("Quarantine"))
        let sneaky = store0.root.path + "/SID/items/../../../Secret/data"
        let (store, id) = try tamperedSession(home, outcome: .pending, stored: sneaky, original: home.path + "/R/data")
        let sneakyResult = try RestoreService(store: store).restore(sessionID: id, onConflict: .skip)
        #expect(sneakyResult.skipped.first?.reason == "manifest entry points outside quarantine")

        let items = store.itemsDirectory(id).appendingPathComponent("f").path
        try Data([1]).write(to: URL(fileURLWithPath: items))
        for original in ["relative/path", home.path + "/a/../b"] {
            var session = try store.read(id: id)
            session.entries[0] = ManifestEntry(
                id: 0, originalPath: original, storedPath: items, size: 1, ruleID: "r", mode: .quarantine,
                outcome: .quarantined, reason: nil)
            try store.write(session)
            let result = try RestoreService(store: store).restore(sessionID: id, onConflict: .skip)
            #expect(result.skipped.first?.reason == "manifest entry points outside quarantine")
        }
        #expect(FileManager.default.fileExists(atPath: secret))
        #expect(FileManager.default.fileExists(atPath: items))
    }

    @Test func trashedEntriesMustLiveInATrash() throws {
        let home = try TempDirectory()
        let outside = try home.file("Documents/notes", bytes: 2)
        let inTrash = try home.file(".Trash/notes", bytes: 2)
        let a = try tamperedSession(home, outcome: .trashed, stored: outside, original: home.path + "/x/notes")
        let bad = try RestoreService(store: a.0).restore(sessionID: a.1, onConflict: .skip)
        #expect(bad.skipped.first?.reason == "manifest entry points outside quarantine")
        #expect(FileManager.default.fileExists(atPath: outside))

        let b = try tamperedSession(home, outcome: .trashed, stored: inTrash, original: home.path + "/x/notes")
        let good = try RestoreService(store: b.0).restore(sessionID: b.1, onConflict: .skip)
        #expect(good.restored == [home.path + "/x/notes"])
    }

    @Test func replaceFailureMovesDisplacedFileBack() throws {
        let home = try TempDirectory()
        let path = try home.file("a/f.txt", bytes: 5)
        let (store, report) = try quarantine(home, [path])
        try home.file("a/f.txt", bytes: 1)
        let stored = try #require(report.manifest.entries.first?.storedPath)
        let bin = try home.directory("FakeTrash")
        let trash: TrashOperation = { source in
            let destination = bin + "/moved"
            try FileManager.default.moveItem(atPath: source, toPath: destination)
            try FileManager.default.removeItem(atPath: stored)
            return destination
        }
        let result = try RestoreService(store: store, trash: trash).restore(
            sessionID: report.manifest.id, onConflict: .replace)
        #expect(result.restored.isEmpty)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).count == 1)
    }

    @Test func replaceFailureReportsWhereDisplacedFileWent() throws {
        let home = try TempDirectory()
        let path = try home.file("a/f.txt", bytes: 5)
        let (store, report) = try quarantine(home, [path])
        try home.file("a/f.txt", bytes: 1)
        let stored = try #require(report.manifest.entries.first?.storedPath)
        let bin = try home.directory("FakeTrash")
        let trash: TrashOperation = { source in
            let destination = bin + "/moved"
            try FileManager.default.moveItem(atPath: source, toPath: destination)
            try FileManager.default.removeItem(atPath: stored)
            try Data([9]).write(to: URL(fileURLWithPath: source))  // blocks the move back
            return destination
        }
        let result = try RestoreService(store: store, trash: trash).restore(
            sessionID: report.manifest.id, onConflict: .replace)
        let reason = try #require(result.skipped.first?.reason)
        #expect(reason.contains("your current file was moved to \(bin)/moved"))
    }

    @Test func manifestWriteFailureIsReportedNotThrown() throws {
        let home = try TempDirectory()
        let path = try home.file("a", bytes: 1)
        let (store, report) = try quarantine(home, [path])
        let dir = store.sessionDirectory(report.manifest.id).path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir) }
        let result = try RestoreService(store: store).restore(sessionID: report.manifest.id, onConflict: .skip)
        #expect(result.restored == [path])
        #expect(result.skipped.contains { $0.path == "<manifest>" && $0.reason.hasPrefix("could not update history") })
    }

    @Test func undeletableItemsLeaveManifestUnchangedForRetry() throws {
        let home = try TempDirectory()
        let store = QuarantineStore(root: home.url.appendingPathComponent("Quarantine"))
        let now = Date()
        var old = try store.createSession(now: now.addingTimeInterval(-10 * 86_400))
        let items = store.itemsDirectory(old.id)
        let stored = items.appendingPathComponent("f").path
        try Data([1]).write(to: URL(fileURLWithPath: stored))
        old.entries = [
            ManifestEntry(
                id: 0, originalPath: "/x", storedPath: stored, size: 1, ruleID: "r", mode: .quarantine,
                outcome: .quarantined, reason: nil)
        ]
        try store.write(old)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: items.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: items.path) }

        #expect(Purger(store: store).purge(retentionDays: 7, now: now).isEmpty)
        let reloaded = try store.read(id: old.id)
        #expect(reloaded.purgedAt == nil)
        #expect(reloaded.entries.first?.outcome == .quarantined)
    }

    @Test func bootstrapFailureRemovesPlist() throws {
        let home = try TempDirectory()
        let runner = FakeCommandRunner()
        let schedule = PurgeSchedule(home: home.path, runner: runner, uid: 501)
        runner.respond("/bin/launchctl bootstrap gui/501 \(schedule.plistURL.path)", status: 1, stderr: "nope")
        #expect(throws: ScheduleError.launchctl("nope")) { try schedule.enable(executable: "/x/openclean") }
        #expect(!schedule.isEnabled)
    }
}
