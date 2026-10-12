import Foundation
import RuleKit
import ScanEngine
import Testing
import TestSupport
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
        #expect(checker(home).check(item, rule: rule()) == .protected("inside protected location \(home.path)/Documents"))
    }

    @Test func neverPassesReportOnlyItems() throws {
        let home = try TempDirectory()
        let item = ScanItem.virtual(path: "tmsnapshot://x", ruleID: "r", hint: nil)
        #expect(checker(home).check(item, rule: rule()) == .reportOnly)
    }

    @Test func parsesLsofFieldOutput() {
        let text = "p123\nfcwd\nn/Users/a\nf4\nn/Users/a/file.db\nf5\nnlocalhost:443->x\np456\nf1\nn/dev/null\n"
        #expect(LsofParser.paths(from: text) == ["/Users/a", "/Users/a/file.db", "/dev/null"])
    }

    @Test func lsofSeesFilesOpenInThisProcess() throws {
        let home = try TempDirectory()
        let file = try home.file("cache/open.db", bytes: 10)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
        defer { try? handle.close() }
        #expect(try LsofOpenFilesProvider().openPaths().contains(file))
    }
}
