import Foundation
import RuleKit
import ScanEngine
import TestSupport
import Testing

@testable import Quarantine

struct PreDeleteCheckerTests {
    func rule(appNotRunning: [String] = []) -> Rule {
        Rule(
            id: "r", name: "R", category: .user, explain: "x", paths: ["~/x"], safety: .regenerable,
            conditions: RuleConditions(appNotRunning: appNotRunning))
    }

    func checker(
        _ home: TempDirectory, running: Set<String> = [], openPaths: Set<String>? = []
    ) -> PreDeleteChecker {
        PreDeleteChecker(
            denyList: DenyList(home: home.path), processChecker: FakeProcessChecker(running: running),
            openPaths: openPaths)
    }

    @Test func passesUnchangedItem() throws {
        let home = try TempDirectory()
        let item = try #require(ScanItem.snapshot(of: try home.file("cache/a", bytes: 10), ruleID: "r"))
        #expect(checker(home).check(item, rule: rule()) == nil)
    }

    @Test func skipsMissingItem() throws {
        let home = try TempDirectory()
        let path = try home.file("cache/a", bytes: 10)
        let item = try #require(ScanItem.snapshot(of: path, ruleID: "r"))
        try FileManager.default.removeItem(atPath: path)
        #expect(checker(home).check(item, rule: rule()) == .missing)
    }

    @Test func skipsChangedItem() throws {
        let home = try TempDirectory()
        let path = try home.file("cache/a", bytes: 10)
        let item = try #require(ScanItem.snapshot(of: path, ruleID: "r"))
        try FileManager.default.setAttributes(
            [.modificationDate: item.modificationDate.addingTimeInterval(10)], ofItemAtPath: path)
        #expect(checker(home).check(item, rule: rule()) == .changedSinceScan)
    }

    @Test func skipsReplacedItem() throws {
        let home = try TempDirectory()
        let path = try home.file("cache/a", bytes: 10)
        let item = try #require(ScanItem.snapshot(of: path, ruleID: "r"))
        try FileManager.default.removeItem(atPath: path)
        try home.file("cache/a", bytes: 10, modified: item.modificationDate)
        #expect(checker(home).check(item, rule: rule()) == .changedSinceScan)
    }

    @Test func skipsItemsContainingOpenFiles() throws {
        let home = try TempDirectory()
        let dir = try home.directory("cache/db")
        try home.file("cache/db/store.sqlite", bytes: 10)
        let item = try #require(ScanItem.snapshot(of: dir, ruleID: "r"))
        let busy = checker(home, openPaths: [dir + "/store.sqlite"])
        #expect(busy.check(item, rule: rule()) == .inUse)
    }

    @Test func skipsEverythingWhenOpenFilesAreUnknown() throws {
        let home = try TempDirectory()
        let item = try #require(ScanItem.snapshot(of: try home.file("cache/a", bytes: 10), ruleID: "r"))
        #expect(checker(home, openPaths: nil).check(item, rule: rule()) == .openFilesUnknown)
    }

    @Test func skipsWhenAppStartedSinceScan() throws {
        let home = try TempDirectory()
        let item = try #require(ScanItem.snapshot(of: try home.file("cache/a", bytes: 10), ruleID: "r"))
        let result = checker(home, running: ["com.example"]).check(item, rule: rule(appNotRunning: ["com.example"]))
        #expect(result == .appRunning("com.example"))
    }

    @Test func skipsProtectedPaths() throws {
        let home = try TempDirectory()
        let item = try #require(ScanItem.snapshot(of: try home.file("Documents/a", bytes: 10), ruleID: "r"))
        #expect(
            checker(home).check(item, rule: rule()) == .protected("inside protected location \(home.path)/Documents"))
    }

    @Test func neverPassesReportOnlyItems() throws {
        let home = try TempDirectory()
        let item = ScanItem.virtual(path: "tmsnapshot://x", ruleID: "r", hint: nil)
        #expect(checker(home).check(item, rule: rule()) == .reportOnly)
    }

    @Test func parsesLsofFieldOutput() throws {
        let text =
            "p123\0\nfcwd\0\nn/Users/a\0\nf4\0\nn/Users/a/file.db\0\nf5\0\nnlocalhost:443->x\0\np456\0\nn/tmp/a\nb\0\n"
        #expect(try LsofParser.paths(from: Data(text.utf8)) == ["/Users/a", "/Users/a/file.db", "/tmp/a\nb"])
    }

    @Test func rejectsNonUTF8Paths() {
        let data = Data([0x6E, 0x2F, 0xFF, 0x00])
        #expect(throws: LsofError.unreadablePath) { try LsofParser.paths(from: data) }
    }

    @Test func lsofRejectsUnexpectedStatusAndEmptyOutput() throws {
        let command = "/usr/sbin/lsof -n -P -w -F0n"
        for status: Int32 in [2, 143] {
            let runner = FakeCommandRunner()
            runner.respond(command, status: status, stdout: "n/a\0")
            #expect(throws: LsofError.unexpectedStatus(status)) {
                try LsofOpenFilesProvider(runner: runner).openPaths()
            }
        }
        let empty = FakeCommandRunner()
        empty.respond(command, status: 1)
        #expect(throws: LsofError.noOutput(status: 1)) { try LsofOpenFilesProvider(runner: empty).openPaths() }
        let ok = FakeCommandRunner()
        ok.respond(command, status: 1, stdout: "n/a\0")
        #expect(try LsofOpenFilesProvider(runner: ok).openPaths() == ["/a"])
    }

    @Test func matchesOpenPathsAcrossCaseSlashAndNormalization() throws {
        let home = try TempDirectory()
        let dir = try home.directory("Cache/Stör")
        let item = try #require(ScanItem.snapshot(of: dir, ruleID: "r"))
        let open: Set<String> = [dir.uppercased().decomposedStringWithCanonicalMapping + "/Store.db"]
        let variants = [
            dir, dir.lowercased(), dir + "/", dir.decomposedStringWithCanonicalMapping,
            dir.precomposedStringWithCanonicalMapping,
        ]
        for variant in variants {
            let alias = ScanItem(
                path: variant, ruleID: "r", size: item.size, device: item.device, inode: item.inode,
                modificationDate: item.modificationDate, ownerUID: item.ownerUID)
            #expect(checker(home, openPaths: open).check(alias, rule: rule()) == .inUse, "\(variant)")
        }
    }

    @Test func lsofSeesFilesOpenInThisProcess() throws {
        let home = try TempDirectory()
        let file = try home.file("cache/open.db", bytes: 10)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
        defer { try? handle.close() }
        #expect(try LsofOpenFilesProvider().openPaths().contains(file))
    }
}
