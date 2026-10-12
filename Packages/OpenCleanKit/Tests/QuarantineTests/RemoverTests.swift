import Foundation
import Privilege
import RuleKit
import ScanEngine
import TestSupport
import Testing

@testable import Quarantine

struct RemoverTests {
    func request(
        _ path: String, safety: SafetyLevel = .regenerable, deleteMode: DeleteMode? = nil,
        requires: [Requirement] = []
    ) throws -> RemovalRequest {
        let rule = Rule(
            id: "r.\(safety.rawValue)", name: "R", category: .user, explain: "x", paths: ["~/x"],
            safety: safety, deleteMode: deleteMode, requires: requires)
        return RemovalRequest(item: try #require(ScanItem.snapshot(of: path, ruleID: rule.id)), rule: rule)
    }

    func remover(
        _ home: TempDirectory, admin: any AdminExecutor = FakeAdminExecutor(),
        deviceOf: @escaping @Sendable (String) -> Int32? = { FileStat.of($0)?.device },
        trash: @escaping TrashOperation = { _ in nil },
        parentIsProtected: @escaping @Sendable (String) -> Bool = { _ in true }
    ) -> (Remover, QuarantineStore) {
        let store = QuarantineStore(root: home.url.appendingPathComponent("Quarantine"))
        let checker = PreDeleteChecker(
            denyList: DenyList(home: home.path), processChecker: FakeProcessChecker(), openPaths: [])
        return (
            Remover(
                store: store, checker: checker, admin: admin, deviceOf: deviceOf, trash: trash,
                parentIsProtected: parentIsProtected), store
        )
    }

    @Test func deletesRegenerableItemsImmediately() throws {
        let home = try TempDirectory()
        let path = try home.file("Library/Caches/a/blob", bytes: 4_096)
        let (remover, _) = remover(home)
        let report = try remover.remove([try request(home.path + "/Library/Caches/a")])
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(report.manifest.entries.map(\.outcome) == [.deleted])
        #expect(report.deletedBytes >= 4_096)
        #expect(!report.hadSkips)
    }

    @Test func quarantinesReviewItemsOnTheSameVolume() throws {
        let home = try TempDirectory()
        let path = try home.file("Downloads/old.dmg", bytes: 2_048)
        let (remover, store) = remover(home)
        let report = try remover.remove([try request(path, safety: .review)])
        let entry = try #require(report.manifest.entries.first)
        let stored = try #require(entry.storedPath)
        #expect(entry.outcome == .quarantined)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(pathIsWithin(stored, store.itemsDirectory(report.manifest.id).path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: stored)) == Data(repeating: 0xAB, count: 2_048))
        #expect(report.quarantinedBytes >= 2_048)
    }

    @Test func usesTrashForItemsOnOtherVolumes() throws {
        let home = try TempDirectory()
        let path = try home.file("Volume/file.bin", bytes: 10)
        let fakeTrash = try home.directory("FakeTrash")
        let (remover, _) = remover(
            home,
            deviceOf: { pathIsWithin($0, path) ? 999 : FileStat.of($0)?.device },
            trash: { source in
                let destination = fakeTrash + "/" + (source as NSString).lastPathComponent
                try FileManager.default.moveItem(atPath: source, toPath: destination)
                return destination
            })
        let report = try remover.remove([try request(path, safety: .review)])
        #expect(report.manifest.entries.first?.outcome == .trashed)
        #expect(report.manifest.entries.first?.storedPath == fakeTrash + "/file.bin")
    }

    @Test func missingItemIsSkippedNotFailed() throws {
        let home = try TempDirectory()
        let path = try home.file("Library/Caches/gone", bytes: 10)
        let req = try request(path)
        try FileManager.default.removeItem(atPath: path)
        let report = try remover(home).0.remove([req])
        #expect(report.manifest.entries.first?.outcome == .skipped)
        #expect(report.manifest.entries.first?.reason == "no longer exists")
        #expect(report.hadSkips)
    }

    @Test func reportOnlyItemsAreNeverRemoved() throws {
        let home = try TempDirectory()
        let path = try home.file("Docker.raw", bytes: 10)
        let real = try request(path)
        let item = ScanItem(
            path: real.item.path, ruleID: "r", size: 10, device: real.item.device, inode: real.item.inode,
            modificationDate: real.item.modificationDate, ownerUID: real.item.ownerUID, reportOnly: true)
        let report = try remover(home).0.remove([RemovalRequest(item: item, rule: real.rule)])
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(report.manifest.entries.first?.outcome == .skipped)
    }

    @Test func adminItemsShareOnePrompt() throws {
        let home = try TempDirectory()
        let a = try home.file("sys/a", bytes: 10)
        let b = try home.file("sys/b", bytes: 10)
        let admin = FakeAdminExecutor(outcome: .succeeded, runForReal: true)
        let report = try remover(home, admin: admin).0.remove([
            try request(a, requires: [.admin]), try request(b, requires: [.admin]),
        ])
        #expect(admin.commands.count == 1)
        #expect(report.manifest.entries.map(\.outcome) == [.deleted, .deleted])
        #expect(!FileManager.default.fileExists(atPath: a))
    }

    @Test func cancelledAdminPromptSkipsAndKeepsFiles() throws {
        let home = try TempDirectory()
        let a = try home.file("sys/a", bytes: 10)
        let admin = FakeAdminExecutor(outcome: .cancelled)
        let report = try remover(home, admin: admin).0.remove([try request(a, requires: [.admin])])
        #expect(FileManager.default.fileExists(atPath: a))
        #expect(report.manifest.entries.first?.outcome == .skipped)
        #expect(report.manifest.entries.first?.reason == "administrator prompt was cancelled")
    }

    @Test func pathsWithNewlinesNeverReachTheAdminPrompt() throws {
        let home = try TempDirectory()
        let odd = try home.file("sys/line\nbreak", bytes: 10)
        let admin = FakeAdminExecutor()
        let report = try remover(home, admin: admin).0.remove([try request(odd, requires: [.admin])])
        #expect(admin.commands.isEmpty)
        #expect(report.manifest.entries.first?.reason == SkipReason.adminUnsupportedPath.description)
    }

    @Test func persistsTheFinalManifest() throws {
        let home = try TempDirectory()
        let path = try home.file("Library/Caches/x", bytes: 10)
        let (remover, store) = remover(home)
        let report = try remover.remove([try request(path)])
        #expect(try store.read(id: report.manifest.id) == report.manifest)
    }

    // MARK: Ancestor-ownership guard (ruling 11)

    @Test func adminItemWithUnprotectedParentIsSkippedByDefaultCheck() throws {
        let home = try TempDirectory()
        let a = try home.file("sys/a", bytes: 10)
        let admin = FakeAdminExecutor(runForReal: true)
        let report = try remover(home, admin: admin, parentIsProtected: Remover.systemParentIsProtected)
            .0.remove([try request(a, requires: [.admin])])
        #expect(admin.commands.isEmpty)
        #expect(FileManager.default.fileExists(atPath: a))
        #expect(report.manifest.entries.first?.outcome == .skipped)
        #expect(report.manifest.entries.first?.reason == "a parent folder is not protected by the system")
    }

    @Test func systemParentIsProtectedForLibraryCaches() {
        // /Library is root-owned and not user-writable on a normal Mac. If /Library/Caches is writable
        // for this user the answer may legitimately differ, so only the type is meaningful there.
        let result = Remover.systemParentIsProtected("/Library/Caches/x")
        if access("/Library/Caches", W_OK) != 0 {
            #expect(result)
        } else {
            #expect(result == false)
        }
    }

    @Test func symlinkedAncestorIsNeverProtected() throws {
        let home = try TempDirectory()
        _ = try home.directory("real")
        try home.symlink("link", to: home.path + "/real")
        #expect(!Remover.systemParentIsProtected(home.path + "/link/x"))
    }

    @Test func partlyFailedAdminBatchReportsPerItem() throws {
        let home = try TempDirectory()
        let a = try home.file("sys/a", bytes: 10)
        let b = try home.file("sys/b", bytes: 10)
        let admin = PartialAdmin(deleting: a)
        let report = try remover(home, admin: admin).0.remove([
            try request(a, requires: [.admin]), try request(b, requires: [.admin]),
        ])
        #expect(report.manifest.entries.map(\.outcome) == [.deleted, .failed])
        #expect(report.manifest.entries[1].reason == "rm: b: Operation not permitted")
    }

    @Test func adminRuleWithQuarantineModeIsSkipped() throws {
        let home = try TempDirectory()
        let a = try home.file("sys/a", bytes: 10)
        let admin = FakeAdminExecutor(runForReal: true)
        let report = try remover(home, admin: admin).0.remove([
            try request(a, safety: .review, requires: [.admin])
        ])
        #expect(admin.commands.isEmpty)
        #expect(FileManager.default.fileExists(atPath: a))
        #expect(report.manifest.entries.first?.reason == "system items can only be deleted, not quarantined")
    }

    @Test func oneBadAdminPathDoesNotFailTheBatch() throws {
        let home = try TempDirectory()
        let bad = try home.file("sys/line\nbreak", bytes: 10)
        let good = try home.file("sys/good", bytes: 10)
        let admin = FakeAdminExecutor()  // records only; the command is not run
        let report = try remover(home, admin: admin).0.remove([
            try request(bad, requires: [.admin]), try request(good, requires: [.admin]),
        ])
        #expect(admin.commands == ["/bin/rm -rf -- '\(good)'"])
        #expect(report.manifest.entries.first?.outcome == .skipped)
        #expect(report.manifest.entries.first?.reason == SkipReason.adminUnsupportedPath.description)
    }

    @Test func userOwnedStickyParentIsNeverProtected() throws {
        let home = try TempDirectory()
        let sticky = try home.directory("sticky")
        // A root-owned, readable file to hard link; skip if the machine has none on this volume.
        let candidates = ["/private/etc/hosts", "/private/etc/shells", "/private/etc/paths"]
        let source = try #require(candidates.first { FileStat.of($0)?.ownerUID == 0 })
        let linked = sticky + "/rootfile"
        guard link(source, linked) == 0 else {
            Issue.record("cannot hard link \(source): \(String(cString: strerror(errno)))")
            return
        }
        #expect(FileStat.of(linked)?.ownerUID == 0)
        chmod(sticky, 0o1755)
        defer { chmod(sticky, 0o755) }
        #expect(FileStat.of(sticky)?.ownerUID != 0)
        #expect(!Remover.ancestorIsProtected(sticky, next: linked))
        #expect(!Remover.systemParentIsProtected(linked))
    }

    @Test func protectedParentRules() throws {
        let home = try TempDirectory()
        #expect(!Remover.systemParentIsProtected(home.path + "/x"))
        #expect(Remover.systemParentIsProtected("/Library/Logs/x"))
        // Sticky /Library/Caches: protected only when the entry itself is root-owned.
        if let stat = FileStat.of("/Library/Caches/ColorSync"), stat.ownerUID == 0, !stat.isSymlink {
            #expect(Remover.systemParentIsProtected("/Library/Caches/ColorSync"))
        }
        if let stat = FileStat.of("/Library/Caches/SiriTTS"), stat.ownerUID != 0 {
            #expect(!Remover.systemParentIsProtected("/Library/Caches/SiriTTS"))
        }
    }
}

/// Deletes one chosen file for real, then reports failure, like a partly failed `rm`.
final class PartialAdmin: AdminExecutor, @unchecked Sendable {
    let path: String
    init(deleting path: String) { self.path = path }
    func runAsAdmin(_ command: RemovalCommand) -> AdminRunOutcome {
        try? FileManager.default.removeItem(atPath: path)
        return .failed("rm: b: Operation not permitted")
    }
}
