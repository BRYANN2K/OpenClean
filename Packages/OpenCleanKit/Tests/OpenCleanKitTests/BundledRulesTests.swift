import Foundation
import Probes
import RuleKit
import ScanEngine
import Testing
@testable import OpenCleanKit

struct BundledRulesTests {
    func load() throws -> LoadedRules {
        let directory = try #require(RulesLocator.bundledDirectory(environment: [:]))
        let linter = RuleLinter(home: "/Users/linttest", knownProbes: ProbeRegistry.standard.ids)
        return RuleCatalog.load(directories: [directory], linter: linter)
    }

    @Test func everyBundledPackLintsClean() throws {
        let loaded = try load()
        #expect(loaded.problems.isEmpty, "\(loaded.problems)")
        #expect(loaded.rules.count == 29)
    }

    @Test func everyCategoryHasRules() throws {
        #expect(Set(try load().rules.map(\.category)) == Set(RuleCategory.allCases))
    }

    @Test func safetyPolicyHolds() throws {
        let rules = try load().rules
        #expect(rules.filter { $0.category == .ai }.allSatisfy { $0.safety == .review })
        #expect(rules.filter { $0.needs(.admin) }.allSatisfy { $0.safety == .regenerable })
        #expect(rules.first { $0.id == "ios.backups" }?.conditions.minAgeDays == 90)
        #expect(rules.first { $0.id == "trash.user" }?.effectiveDeleteMode == .immediate)
        #expect(rules.filter { $0.category == .browsers }.allSatisfy { !$0.conditions.appNotRunning.isEmpty })
    }
}
