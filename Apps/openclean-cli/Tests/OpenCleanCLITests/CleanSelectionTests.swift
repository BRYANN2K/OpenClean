import Foundation
import RuleKit
import ScanEngine
import Testing

@testable import OpenCleanCLI

struct CleanSelectionTests {
    let regenerable = Rule(
        id: "a.regen", name: "A", category: .user, explain: "x", paths: ["~/a/*"], safety: .regenerable)
    let review = Rule(id: "b.review", name: "B", category: .developer, explain: "x", paths: ["~/b/*"], safety: .review)
    let caution = Rule(id: "c.caution", name: "C", category: .user, explain: "x", paths: ["~/c/*"], safety: .caution)

    func result() -> ScanResult {
        func item(_ path: String, _ rule: String) -> ScanItem {
            ScanItem(path: path, ruleID: rule, size: 1, device: 1, inode: 1, modificationDate: .now, ownerUID: 0)
        }
        return ScanResult(
            rules: [
                RuleResult(rule: regenerable, items: [item("/a/1", regenerable.id)]),
                RuleResult(rule: review, items: [item("/b/1", review.id)]),
                RuleResult(rule: caution, items: [item("/c/1", caution.id)]),
            ], isComplete: true, startedAt: .now, finishedAt: .now)
    }

    @Test func rulesFilterByCategoryAndHideCaution() {
        let all = [regenerable, review, caution]
        #expect(CleanSelection.rules(from: all, categories: [], ruleIDs: []).map(\.id) == ["a.regen", "b.review"])
        #expect(CleanSelection.rules(from: all, categories: [.developer], ruleIDs: []).map(\.id) == ["b.review"])
        #expect(CleanSelection.rules(from: all, categories: [], ruleIDs: ["c.caution"]).map(\.id) == ["c.caution"])
    }

    @Test func pathsRespectSafetyFlags() {
        #expect(CleanSelection.paths(in: result(), includeReview: false, explicitRuleIDs: []) == ["/a/1"])
        #expect(CleanSelection.paths(in: result(), includeReview: true, explicitRuleIDs: []) == ["/a/1", "/b/1"])
        #expect(
            CleanSelection.paths(in: result(), includeReview: true, explicitRuleIDs: ["c.caution"])
                == ["/a/1", "/b/1", "/c/1"])
        #expect(CleanSelection.paths(in: result(), includeReview: false, explicitRuleIDs: ["c.caution"]) == ["/a/1"])
    }

    @Test func excludingAdminDropsOnlyAdminItems() {
        let admin = Rule(
            id: "s.admin", name: "S", category: .system, explain: "x", paths: ["/s/*"], safety: .regenerable,
            requires: [.admin])
        let item = ScanItem(
            path: "/s/1", ruleID: admin.id, size: 1, device: 1, inode: 1, modificationDate: .now, ownerUID: 0)
        var withAdmin = result()
        withAdmin.rules.append(RuleResult(rule: admin, items: [item]))

        let filtered = CleanSelection.excludingAdmin(["/a/1", "/b/1", "/s/1"], in: withAdmin)
        #expect(filtered.kept == ["/a/1", "/b/1"])
        #expect(filtered.dropped == 1)

        let untouched = CleanSelection.excludingAdmin(["/a/1"], in: withAdmin)
        #expect(untouched.kept == ["/a/1"])
        #expect(untouched.dropped == 0)
    }
}
