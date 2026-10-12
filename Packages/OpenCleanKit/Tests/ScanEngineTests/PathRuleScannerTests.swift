import Foundation
import RuleKit
import TestSupport
import Testing

@testable import ScanEngine

struct PathRuleScannerTests {
    func context(
        _ home: TempDirectory, fda: Bool = true, running: Set<String> = [],
        excludes: [String] = [], now: Date = .now
    ) -> ScanContext {
        ScanContext(
            home: home.path, hasFullDiskAccess: fda, processChecker: FakeProcessChecker(running: running),
            userExcludes: excludes, now: now)
    }

    func rule(
        _ paths: [String], exclude: [String] = [], conditions: RuleConditions = RuleConditions(),
        requires: [Requirement] = []
    ) -> Rule {
        Rule(
            id: "test.rule", name: "Test", category: .user, explain: "x", paths: paths,
            safety: .regenerable, conditions: conditions, exclude: exclude, requires: requires)
    }

    func scan(_ rule: Rule, _ context: ScanContext) -> RuleResult {
        PathRuleScanner().scan(rule, context: context, ledger: HardLinkLedger())
    }

    @Test func matchesEntriesWithAllocatedSizesLargestFirst() throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/small/f", bytes: 4_096)
        try home.file("Library/Caches/big/f", bytes: 65_536)
        let result = scan(rule(["~/Library/Caches/*"]), context(home))
        #expect(result.status == .scanned)
        #expect(result.items.map(\.path) == [home.path + "/Library/Caches/big", home.path + "/Library/Caches/small"])
        #expect(result.items[0].size >= 65_536)
        #expect(result.items[1].size >= 4_096)
        #expect(result.items.allSatisfy { $0.ruleID == "test.rule" && !$0.reportOnly })
    }

    @Test func appliesRuleExcludes() throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/keep/f", bytes: 10)
        try home.file("Library/Caches/skip-me/f", bytes: 10)
        try home.file("Library/Caches/clean/f", bytes: 10)
        let r = rule(["~/Library/Caches/*"], exclude: ["~/Library/Caches/keep", "*/skip-*"])
        #expect(scan(r, context(home)).items.map(\.path) == [home.path + "/Library/Caches/clean"])
    }

    @Test func userExcludeMatchesCombiningMarkComponentByBytes() throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/\u{0301}keep/f", bytes: 10)
        try home.file("Library/Caches/other/f", bytes: 10)
        let ctx = context(home, excludes: [home.path + "/Library/Caches/\u{0301}keep"])
        let result = scan(rule(["~/Library/Caches/*"]), ctx)
        #expect(result.items.map(\.path) == [home.path + "/Library/Caches/other"])
    }

    @Test func dropsSymlinkThatEscapesIntoDocuments() throws {
        let home = try TempDirectory()
        try home.file("Documents/secret.txt", bytes: 10)
        try home.directory("Library/Caches")
        try home.symlink("Library/Caches/evil", to: home.path + "/Documents")
        let result = scan(rule(["~/Library/Caches/*"]), context(home))
        #expect(result.items.isEmpty)
        #expect(result.errors.contains { $0.contains("symbolic link skipped") })
    }

    @Test func dropsProtectedMatches() throws {
        let home = try TempDirectory()
        try home.file("Documents/a", bytes: 10)
        try home.file("Desktop/b", bytes: 10)
        try home.file("junk/c", bytes: 10)
        let result = scan(rule(["~/*"]), context(home))
        #expect(result.items.map(\.path) == [home.path + "/junk"])
        #expect(result.errors.filter { $0.contains("protected") }.count == 2)
    }

    @Test func honoursMinimumAge() throws {
        let home = try TempDirectory()
        let now = Date()
        try home.file("Library/Logs/old.log", bytes: 10, modified: now.addingTimeInterval(-10 * 86_400))
        try home.file("Library/Logs/new.log", bytes: 10, modified: now)
        let r = rule(["~/Library/Logs/*"], conditions: RuleConditions(minAgeDays: 5))
        #expect(scan(r, context(home, now: now)).items.map(\.path) == [home.path + "/Library/Logs/old.log"])
    }

    @Test func honoursMinimumSize() throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/tiny", bytes: 1_000)
        try home.file("Library/Caches/huge", bytes: 100_000)
        let r = rule(["~/Library/Caches/*"], conditions: RuleConditions(minSize: ByteSize(bytes: 50_000)))
        #expect(scan(r, context(home)).items.map(\.path) == [home.path + "/Library/Caches/huge"])
    }

    @Test func requiresFullDiskAccessWhenDeclared() throws {
        let home = try TempDirectory()
        try home.file(".Trash/x", bytes: 10)
        let result = scan(rule(["~/.Trash/*"], requires: [.fullDiskAccess]), context(home, fda: false))
        #expect(result.status == .needsFullDiskAccess)
        #expect(result.items.isEmpty)
    }

    @Test func skipsWhileAppRunning() throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/x", bytes: 10)
        let r = rule(["~/Library/Caches/*"], conditions: RuleConditions(appNotRunning: ["com.example.app"]))
        let result = scan(r, context(home, running: ["com.example.app"]))
        #expect(result.status == .skippedAppRunning("com.example.app"))
        #expect(result.items.isEmpty)
    }

    @Test func countsHardLinkedFilesOnce() throws {
        let home = try TempDirectory()
        let original = try home.file("Library/Caches/a/data", bytes: 262_144)
        try home.directory("Library/Caches/b")
        try FileManager.default.linkItem(atPath: original, toPath: home.path + "/Library/Caches/b/data")
        let result = scan(rule(["~/Library/Caches/*"]), context(home))
        #expect(result.items.count == 2)
        #expect(result.totalSize >= 262_144)
        #expect(result.totalSize < 2 * 262_144)
    }

    @Test func sparseFilesCountOnlyAllocatedBlocks() throws {
        let home = try TempDirectory()
        let path = try home.file("Library/Caches/sparse.img")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seek(toOffset: 100_000_000)
        try handle.write(contentsOf: Data([1]))
        try handle.close()
        let result = scan(rule(["~/Library/Caches/*"]), context(home))
        #expect(try #require(result.items.first).size < 1_000_000)
    }

    @Test func honoursUserExcludedPaths() throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/mine/f", bytes: 10)
        try home.file("Library/Caches/other/f", bytes: 10)
        let result = scan(rule(["~/Library/Caches/*"]), context(home, excludes: [home.path + "/Library/Caches/mine"]))
        #expect(result.items.map(\.path) == [home.path + "/Library/Caches/other"])
    }

    @Test func excludeInsideItemSkipsWholeItem() throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/foo/keep/f", bytes: 10)
        try home.file("Library/Caches/other/f", bytes: 10)
        let result = scan(
            rule(["~/Library/Caches/*"]), context(home, excludes: [home.path + "/Library/Caches/foo/keep"]))
        #expect(result.items.map(\.path) == [home.path + "/Library/Caches/other"])
    }

    @Test func symlinkedHomeStillAppliesDenyList() throws {
        let real = try TempDirectory()
        try real.file("Documents/a", bytes: 10)
        try real.file("junk/b", bytes: 10)
        let holder = try TempDirectory()
        let link = try holder.symlink("link", to: real.path)
        let result = scan(
            rule(["~/*"]),
            ScanContext(home: link, hasFullDiskAccess: true, processChecker: FakeProcessChecker()))
        #expect(result.items.map(\.path) == [real.path + "/junk"])
        #expect(result.errors.contains { $0.contains("protected") })
    }

    @Test func excludesMatchIgnoringCaseAndTrailingSlash() throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/mine/f", bytes: 10)
        try home.file("Library/Caches/other/f", bytes: 10)
        let result = scan(
            rule(["~/Library/Caches/*"]),
            context(home, excludes: [(home.path + "/library/caches/MINE/").replacingOccurrences(of: "//", with: "/")]))
        #expect(result.items.map(\.path) == [home.path + "/Library/Caches/other"])
    }

    @Test func snapshotMatchesScannerFields() throws {
        let home = try TempDirectory()
        let path = try home.file("f", bytes: 8_192)
        let item = try #require(ScanItem.snapshot(of: path, ruleID: "r"))
        let stat = try #require(FileStat.of(path))
        #expect(item.inode == stat.inode)
        #expect(item.modificationDate == stat.modificationDate)
        #expect(item.size >= 8_192)
    }
}
