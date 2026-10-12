import Foundation
import Quarantine
import RuleKit
import ScanEngine
import TestSupport
import Testing

@testable import OpenCleanKit

struct CoordinatorTests {
    func coordinator(_ home: TempDirectory, rules: String) -> OpenCleanCoordinator {
        OpenCleanCoordinator(
            home: home.path, environment: ["OPENCLEAN_RULES_DIR": rules], registry: ProbeRegistry([]),
            processChecker: FakeProcessChecker(), openFiles: FakeOpenFiles(), admin: FakeAdminExecutor(),
            fullDiskAccess: { .granted }, trash: { _ in nil })
    }

    @Test func loadsRulesAndHidesCautionUnlessAsked() throws {
        let home = try TempDirectory()
        let subject = coordinator(home, rules: try FixtureRules.writeDirectory(in: home))
        #expect(subject.loadRules(includeCaution: false).rules.map(\.id) == ["fixture.caches", "fixture.downloads"])
        #expect(subject.loadRules(includeCaution: true).rules.count == 3)
        #expect(subject.loadRules(includeCaution: true).problems.isEmpty)
    }

    @Test func skipsInvalidAndDuplicateUserPacks() throws {
        let home = try TempDirectory()
        let subject = coordinator(home, rules: try FixtureRules.writeDirectory(in: home))
        let userRules = subject.paths.userRules.path
        try FileManager.default.createDirectory(atPath: userRules, withIntermediateDirectories: true)
        try """
        pack: evil
        version: 1
        rules:
          - id: evil.docs
            name: Docs
            category: user
            explain: no
            paths: ["~/Documents/*"]
            safety: regenerable
        """.write(toFile: userRules + "/evil.yaml", atomically: true, encoding: .utf8)
        try FixtureRules.yaml.write(toFile: userRules + "/copy.yaml", atomically: true, encoding: .utf8)

        let loaded = subject.loadRules(includeCaution: true)
        #expect(loaded.rules.count == 3)
        #expect(loaded.problems.filter { $0.hasPrefix("Skipped rule pack") }.count == 2)
        #expect(loaded.problems.contains { $0.contains("protected location") })
        #expect(loaded.problems.contains { $0.contains("already defined by another pack") })
    }

    @Test func scanCleanHistoryAndRestoreEndToEnd() async throws {
        let home = try TempDirectory()
        let cache = try home.file("Library/Caches/com.example/blob", bytes: 8_192)
        let download = try home.file("Downloads/old.dmg", bytes: 4_096)
        let subject = coordinator(home, rules: try FixtureRules.writeDirectory(in: home))
        let rules = subject.loadRules(includeCaution: false).rules

        let result = await subject.scan(rules, settings: Settings())
        let defaults = DefaultSelection.paths(in: result)
        #expect(defaults == [home.path + "/Library/Caches/com.example"])

        let plan = CleanupPlan(result: result, selectedPaths: defaults.union([download]))
        #expect(plan.itemCount == 2)
        #expect(plan.immediateBytes >= 8_192)
        #expect(plan.quarantineBytes >= 4_096)

        let report = try subject.execute(plan)
        #expect(!FileManager.default.fileExists(atPath: cache))
        #expect(!FileManager.default.fileExists(atPath: download))
        #expect(!report.hadSkips)

        #expect(subject.history().count == 1)
        let restored = try subject.restore(sessionID: report.manifest.id, onConflict: .skip)
        #expect(restored.restored == [download])
        #expect(FileManager.default.fileExists(atPath: download))
    }

    @Test func honoursExcludedPathsFromSettings() async throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/keep/f", bytes: 10)
        try home.file("Library/Caches/drop/f", bytes: 10)
        let subject = coordinator(home, rules: try FixtureRules.writeDirectory(in: home))
        let rules = subject.loadRules(includeCaution: false).rules
        let result = await subject.scan(rules, settings: Settings(excludedPaths: ["~/Library/Caches/keep"]))
        #expect(result.rule("fixture.caches")?.items.map(\.path) == [home.path + "/Library/Caches/drop"])
    }

    @Test func planNeverIncludesReportOnlyItems() {
        let rule = Rule(id: "d", name: "D", category: .developer, explain: "x", probe: "p", safety: .review)
        let item = ScanItem.virtual(path: "tmsnapshot://x", ruleID: "d", hint: nil)
        let result = ScanResult(
            rules: [RuleResult(rule: rule, items: [item])], isComplete: true, startedAt: .now, finishedAt: .now)
        #expect(CleanupPlan(result: result, selectedPaths: ["tmsnapshot://x"]).isEmpty)
        #expect(DefaultSelection.paths(in: result).isEmpty)
    }

    @Test func settingsRoundTripAndClampRetention() throws {
        let home = try TempDirectory()
        let store = SettingsStore(url: home.url.appendingPathComponent("settings.json"))
        #expect(store.load() == Settings())
        try store.save(Settings(retentionDays: 500, advancedEnabled: true, excludedPaths: ["~/x"]))
        #expect(store.load() == Settings(retentionDays: 90, advancedEnabled: true, excludedPaths: ["~/x"]))
        try Data(#"{"advancedEnabled": true}"#.utf8).write(to: store.url)
        #expect(store.load() == Settings(retentionDays: 7, advancedEnabled: true, excludedPaths: []))
    }

    @Test func rulesLocatorPrefersEnvironmentDirectoryWithPacks() throws {
        let home = try TempDirectory()
        let rules = try FixtureRules.writeDirectory(in: home)
        let empty = try home.directory("empty")
        #expect(RulesLocator.bundledDirectory(environment: ["OPENCLEAN_RULES_DIR": rules])?.path == rules)
        #expect(RulesLocator.bundledDirectory(environment: ["OPENCLEAN_RULES_DIR": empty])?.path != empty)
    }

    @Test func executeDenyListUsesResolvedHomeWhenHomeIsASymlink() throws {
        let real = try TempDirectory()
        let links = try TempDirectory()
        let linkedHome = try links.symlink("home", to: real.path)
        let document = try real.file("Documents/notes.txt", bytes: 64)
        let rules = try FixtureRules.writeDirectory(in: real)
        let symlinked = OpenCleanCoordinator(
            home: linkedHome, environment: ["OPENCLEAN_RULES_DIR": rules],
            registry: ProbeRegistry([]), processChecker: FakeProcessChecker(), openFiles: FakeOpenFiles(),
            admin: FakeAdminExecutor(), fullDiskAccess: { .granted }, trash: { _ in nil })
        #expect(symlinked.home == linkedHome)
        #expect(symlinked.resolvedHome == real.path)

        let rule = Rule(
            id: "evil.docs", name: "Docs", category: .user, explain: "x", paths: ["~/Documents/*"],
            safety: .regenerable)
        let item = try #require(ScanItem.snapshot(of: document, ruleID: rule.id))
        let result = ScanResult(
            rules: [RuleResult(rule: rule, items: [item])], isComplete: true, startedAt: .now, finishedAt: .now)
        let report = try symlinked.execute(CleanupPlan(result: result, selectedPaths: [document]))

        #expect(report.skipped.count == 1)
        #expect(report.skipped.first?.reason?.hasPrefix("protected") == true)
        #expect(FileManager.default.fileExists(atPath: document))
    }

    @Test func homeCanBeOverriddenByEnvironment() throws {
        let home = try TempDirectory()
        let subject = OpenCleanCoordinator(home: "/Users/ignored", environment: ["OPENCLEAN_HOME": home.path])
        #expect(subject.home == home.path)
        #expect(subject.paths.support.path.hasPrefix(home.path))
    }
}
