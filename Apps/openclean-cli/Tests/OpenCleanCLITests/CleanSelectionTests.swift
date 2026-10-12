import Foundation
import RuleKit
import ScanEngine
import Testing
@testable import OpenCleanCLI

struct CleanSelectionTests {
    let regenerable = Rule(id: "a.regen", name: "A", category: .user, explain: "x", paths: ["~/a/*"], safety: .regenerable)
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
}
