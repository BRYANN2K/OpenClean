import Foundation
import RuleKit
import ScanEngine

enum CleanSelection {
    /// Rules named with --rule win; otherwise filter by --category and leave out caution rules.
    static func rules(from all: [Rule], categories: Set<RuleCategory>, ruleIDs: Set<String>) -> [Rule] {
        all.filter { rule in
            if !ruleIDs.isEmpty { return ruleIDs.contains(rule.id) }
            return (categories.isEmpty || categories.contains(rule.category)) && rule.safety != .caution
        }
    }

    /// regenerable: always; review: with --include-review; caution: with --include-review AND named by --rule.
    static func paths(in result: ScanResult, includeReview: Bool, explicitRuleIDs: Set<String>) -> Set<String> {
        var selected = Set<String>()
        for ruleResult in result.rules where ruleResult.status == .scanned {
            let allowed: Bool
            switch ruleResult.rule.safety {
            case .regenerable: allowed = true
            case .review: allowed = includeReview
            case .caution: allowed = includeReview && explicitRuleIDs.contains(ruleResult.rule.id)
            }
            if allowed { selected.formUnion(ruleResult.items.filter { !$0.reportOnly }.map(\.path)) }
        }
        return selected
    }
}
