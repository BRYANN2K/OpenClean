import Foundation
import Testing
@testable import RuleKit

struct RuleLinterTests {
    let linter = RuleLinter(home: "/Users/tester", knownProbes: ["xcode.simulators"])

    func rule(
        id: String = "user.logs", paths: [String] = ["~/Library/Logs/*"], probe: String? = nil,
        safety: SafetyLevel = .regenerable, deleteMode: DeleteMode? = nil,
        requires: [Requirement] = [], minAgeDays: Int? = nil, explain: String = "Apps recreate them."
    ) -> Rule {
        Rule(
            id: id, name: "Name", category: .user, explain: explain, paths: paths, probe: probe,
            safety: safety, deleteMode: deleteMode, conditions: RuleConditions(minAgeDays: minAgeDays),
            requires: requires)
    }

    func messages(_ r: Rule) -> [String] { linter.lint(r, pack: "p").map(\.message) }

    @Test func validRuleHasNoIssues() {
        #expect(messages(rule()).isEmpty)
        #expect(messages(rule(paths: [], probe: "xcode.simulators", safety: .review)).isEmpty)
        #expect(messages(rule(paths: ["/Library/Caches/*"], requires: [.admin])).isEmpty)
    }

    @Test func rejectsBadIDs() {
        #expect(messages(rule(id: "Xcode Derived")).contains { $0.hasPrefix("id must be") })
        #expect(messages(rule(id: "xcode..data")).contains { $0.hasPrefix("id must be") })
    }

    @Test func requiresExplanation() {
        #expect(messages(rule(explain: "  ")).contains { $0.hasPrefix("explain is empty") })
    }

    @Test func requiresExactlyOneOfPathsOrProbe() {
        #expect(messages(rule(paths: [])).contains("needs either paths or probe"))
        #expect(messages(rule(probe: "xcode.simulators")).contains("use paths or probe, not both"))
        #expect(messages(rule(paths: [], probe: "nope")).contains("unknown probe nope"))
    }

    @Test(arguments: ["~/Documents/*", "~/*", "/System/Library/Caches/*", "~/Library/*", "/Applications/*", "*/x"])
    func rejectsProtectedOrRelativePaths(pattern: String) {
        #expect(!messages(rule(paths: [pattern])).isEmpty, "expected \(pattern) to be rejected")
    }

    @Test func rejectsTrailingDoubleStar() {
        #expect(messages(rule(paths: ["~/Library/Caches/**"])).contains { $0.hasPrefix("trailing ** is not supported") })
    }

    @Test func adminOnlyForRegenerableImmediateRules() {
        #expect(messages(rule(safety: .review, requires: [.admin])).contains {
            $0 == "requires: admin is only allowed for regenerable rules"
        })
        #expect(messages(rule(deleteMode: .quarantine, requires: [.admin])).contains {
            $0 == "requires: admin rules must delete immediately"
        })
    }

    @Test func rejectsNegativeAge() {
        #expect(messages(rule(minAgeDays: -1)).contains("min_age_days must be >= 0"))
    }

    @Test func detectsDuplicateIDsAcrossPacks() {
        let a = RulePack(pack: "a", rules: [rule(id: "x.y")])
        let b = RulePack(pack: "b", rules: [rule(id: "x.y")])
        let issues = linter.lint([a, b])
        #expect(issues == [LintIssue(pack: "b", ruleID: "x.y", message: "duplicate rule id")])
    }

    @Test func appPathsLiveInApplicationSupport() {
        let paths = AppPaths.standard(home: "/Users/tester")
        #expect(paths.support.path == "/Users/tester/Library/Application Support/OpenClean")
        #expect(paths.quarantine.path == "/Users/tester/Library/Application Support/OpenClean/Quarantine")
        #expect(paths.userRules.path == "/Users/tester/Library/Application Support/OpenClean/rules")
        #expect(paths.settingsFile.lastPathComponent == "settings.json")
    }
}
