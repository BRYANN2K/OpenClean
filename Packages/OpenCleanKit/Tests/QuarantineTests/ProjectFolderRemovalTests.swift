import Darwin
import Foundation
import RuleKit
import ScanEngine
import TestSupport
import Testing

@testable import Quarantine

/// Removal-time checks for project folders (Settings → Project folders), `make_writable` deletes, and the
/// plain-words skip explanations.
struct ProjectFolderRemovalTests {
    let nodeRule = Rule(
        id: "node.project-modules", name: "N", category: .developer, explain: "x", probe: "node.project-modules",
        safety: .review)

    func checker(_ home: TempDirectory, folders: [String]) -> PreDeleteChecker {
        PreDeleteChecker(
            denyList: DenyList(home: home.path), processChecker: FakeProcessChecker(), openPaths: [],
            projectFolders: ProjectFolderExemption(home: home.path, folders: folders))
    }

    func documentsModules(_ home: TempDirectory) throws -> ScanItem {
        try home.file("Documents/Code/app/package.json", bytes: 10)
        try home.file("Documents/Code/app/node_modules/x/index.js", bytes: 100)
        return try #require(
            ScanItem.snapshot(of: home.path + "/Documents/Code/app/node_modules", ruleID: nodeRule.id))
    }

    @Test func passesAnArtifactInAChosenFolder() throws {
        let home = try TempDirectory()
        let item = try documentsModules(home)
        #expect(checker(home, folders: [home.path + "/Documents/Code"]).check(item, rule: nodeRule) == nil)
    }

    @Test func staysProtectedWithoutTheFolderOrForOtherRules() throws {
        let home = try TempDirectory()
        let item = try documentsModules(home)
        let reason = "inside protected location \(home.path)/Documents"
        #expect(checker(home, folders: []).check(item, rule: nodeRule) == .protected(reason))
        let plain = PreDeleteChecker(
            denyList: DenyList(home: home.path), processChecker: FakeProcessChecker(), openPaths: [])
        #expect(plain.check(item, rule: nodeRule) == .protected(reason))
        var immediate = nodeRule
        immediate.safety = .regenerable
        #expect(
            checker(home, folders: [home.path + "/Documents/Code"]).check(item, rule: immediate)
                == .protected(reason))
        let pathRule = Rule(
            id: "evil", name: "E", category: .user, explain: "x", paths: ["~/Documents/*"], safety: .review)
        #expect(
            checker(home, folders: [home.path + "/Documents/Code"]).check(item, rule: pathRule) == .protected(reason))
    }

    @Test func otherChecksStillRunFirst() throws {
        let home = try TempDirectory()
        let item = try documentsModules(home)
        try FileManager.default.setAttributes(
            [.modificationDate: item.modificationDate.addingTimeInterval(10)], ofItemAtPath: item.path)
        #expect(
            checker(home, folders: [home.path + "/Documents/Code"]).check(item, rule: nodeRule) == .changedSinceScan)
        let busy = PreDeleteChecker(
            denyList: DenyList(home: home.path), processChecker: FakeProcessChecker(),
            openPaths: [item.path + "/x/index.js"],
            projectFolders: ProjectFolderExemption(home: home.path, folders: [home.path + "/Documents/Code"]))
        let fresh = try #require(ScanItem.snapshot(of: item.path, ruleID: nodeRule.id))
        #expect(busy.check(fresh, rule: nodeRule) == .inUse)
    }

    @Test func quarantinesTheArtifactAndNothingElse() throws {
        let home = try TempDirectory()
        let item = try documentsModules(home)
        let store = QuarantineStore(root: home.url.appendingPathComponent("Quarantine"))
        let remover = Remover(
            store: store, checker: checker(home, folders: [home.path + "/Documents/Code"]),
            admin: FakeAdminExecutor(), trash: { _ in nil })
        let report = try remover.remove([RemovalRequest(item: item, rule: nodeRule)])
        #expect(report.manifest.entries.map(\.outcome) == [.quarantined])
        #expect(!FileManager.default.fileExists(atPath: item.path))
        #expect(FileManager.default.fileExists(atPath: home.path + "/Documents/Code/app/package.json"))
    }

    // MARK: make_writable

    func goRule(makeWritable: Bool) -> Rule {
        Rule(
            id: "go.module-cache", name: "Go", category: .developer, explain: "x", paths: ["~/go/pkg/mod"],
            safety: .regenerable, makeWritable: makeWritable)
    }

    /// A module cache laid out the way Go leaves it: read-only folders (0555) and files (0444).
    func readOnlyModuleCache(_ home: TempDirectory) throws -> String {
        let root = home.path + "/go/pkg/mod"
        try home.file("go/pkg/mod/github.com/a/b@v1.0.0/b.go", bytes: 100)
        try home.file("go/pkg/mod/github.com/a/b@v1.0.0/sub/c.go", bytes: 100)
        try home.file("go/pkg/mod/cache/download/x.zip", bytes: 100)
        for path in try FileManager.default.subpathsOfDirectory(atPath: root).map({ root + "/" + $0 }) + [root] {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            chmod(path, isDirectory.boolValue ? 0o555 : 0o444)
        }
        return root
    }

    /// Lets `TempDirectory` clean up whatever a test left read-only.
    func unlock(_ path: String) {
        guard let paths = try? FileManager.default.subpathsOfDirectory(atPath: path) else { return }
        chmod(path, 0o755)
        for sub in paths { chmod(path + "/" + sub, 0o755) }
    }

    func remove(_ path: String, rule: Rule, home: TempDirectory) throws -> RemovalReport {
        let item = try #require(ScanItem.snapshot(of: path, ruleID: rule.id))
        let checker = PreDeleteChecker(
            denyList: DenyList(home: home.path), processChecker: FakeProcessChecker(), openPaths: [])
        return try Remover(
            store: QuarantineStore(root: home.url.appendingPathComponent("Quarantine")), checker: checker,
            admin: FakeAdminExecutor(), trash: { _ in nil }
        ).remove([RemovalRequest(item: item, rule: rule)])
    }

    @Test func aPlainDeleteOfAReadOnlyCacheFailsPartway() throws {
        let home = try TempDirectory()
        let root = try readOnlyModuleCache(home)
        defer { unlock(root) }
        let report = try remove(root, rule: goRule(makeWritable: false), home: home)
        #expect(report.manifest.entries.map(\.outcome) == [.failed])
        #expect(FileManager.default.fileExists(atPath: root))
    }

    @Test func makeWritableDeletesAReadOnlyCache() throws {
        let home = try TempDirectory()
        let root = try readOnlyModuleCache(home)
        defer { unlock(root) }
        let report = try remove(root, rule: goRule(makeWritable: true), home: home)
        #expect(report.manifest.entries.map(\.outcome) == [.deleted])
        #expect(!FileManager.default.fileExists(atPath: root))
        #expect(FileManager.default.fileExists(atPath: home.path + "/go/pkg"))
    }

    /// Defence in depth behind the linter: the Remover only prepares regenerable rules' items.
    @Test func makeWritableIsIgnoredForRulesThatAreNotRegenerable() throws {
        let home = try TempDirectory()
        let root = try readOnlyModuleCache(home)
        defer { unlock(root) }
        var rule = goRule(makeWritable: true)
        rule.safety = .review
        rule.deleteMode = .immediate
        let report = try remove(root, rule: rule, home: home)
        #expect(report.manifest.entries.map(\.outcome) == [.failed])
        var info = stat()
        #expect(lstat(root + "/github.com", &info) == 0)
        #expect(info.st_mode & S_IWUSR == 0)
    }

    @Test func makeWritableNeverFollowsSymlinksOutOfTheItem() throws {
        let home = try TempDirectory()
        let outside = try TempDirectory()
        let keep = try outside.directory("keep")
        try outside.file("keep/file", bytes: 10)
        chmod(keep, 0o555)
        defer { chmod(keep, 0o755) }
        let root = try readOnlyModuleCache(home)
        defer { unlock(root) }
        chmod(root, 0o755)
        try home.symlink("go/pkg/mod/link", to: keep)
        chmod(root, 0o555)

        try WritableTree.prepare(
            root, device: try #require(FileStat.of(root)).device, inode: try #require(FileStat.of(root)).inode)
        var info = stat()
        #expect(lstat(keep, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o555)
        #expect(lstat(root + "/github.com", &info) == 0)
        #expect(info.st_mode & S_IWUSR != 0)
        // Files are never changed.
        #expect(lstat(root + "/github.com/a/b@v1.0.0/b.go", &info) == 0)
        #expect(info.st_mode & 0o777 == 0o444)
    }

    @Test func makeWritableRefusesASwappedItem() throws {
        let home = try TempDirectory()
        let root = try readOnlyModuleCache(home)
        defer { unlock(root) }
        let stat = try #require(FileStat.of(root))
        #expect(throws: WritableTree.Problem.self) {
            try WritableTree.prepare(root, device: stat.device, inode: stat.inode + 1)
        }
    }

    // MARK: Skip explanations

    @Test func everySkipReasonReadsBackAndHasPlainWords() {
        let reasons: [SkipReason] =
            SkipReason.withoutValues + [.appRunning("com.example.app"), .protected("inside protected location /x")]
        for reason in reasons {
            #expect(SkipReason(recorded: reason.description) == reason, "\(reason)")
            #expect(!reason.plainExplanation.isEmpty)
        }
        #expect(SkipReason.changedSinceScan.plainExplanation == "Changed since the scan; an app may be using it.")
        #expect(SkipReason(recorded: "Permission denied") == nil)
    }

    @Test func manifestEntriesExplainThemselves() {
        func entry(_ outcome: EntryOutcome, _ reason: String?) -> ManifestEntry {
            ManifestEntry(
                id: 0, originalPath: "/x", storedPath: nil, size: 1, ruleID: "r", mode: .immediate, outcome: outcome,
                reason: reason)
        }
        #expect(
            entry(.skipped, SkipReason.inUse.description).plainSkipExplanation
                == "Open in another app. Quit the app, then scan again.")
        #expect(entry(.skipped, SkipReason.inUse.description).isWorthRescanning)
        #expect(!entry(.skipped, SkipReason.protected("p").description).isWorthRescanning)
        #expect(entry(.failed, "Permission denied.").plainSkipExplanation == "Permission denied.")
        #expect(entry(.failed, nil).plainSkipExplanation == "Couldn't be removed.")
        #expect(entry(.deleted, nil).plainSkipExplanation == nil)
    }
}
