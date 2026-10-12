import Darwin
import Foundation
import RuleKit

/// Scans a rule that lists `paths`. Synchronous; checks task cancellation between matches.
public struct PathRuleScanner: Sendable {
    public init() {}

    public func scan(_ rule: Rule, context: ScanContext, ledger: HardLinkLedger) -> RuleResult {
        var result = RuleResult(rule: rule)
        if let blocked = Gate.check(rule, context) {
            result.status = blocked
            return result
        }
        let expander = context.expander
        let excludes = rule.exclude.map(expander.expand)

        patterns: for pattern in rule.paths {
            if Task.isCancelled {
                result.status = .cancelled
                break
            }
            let expanded = expander.expand(pattern)
            guard let prefixReal = realPath(GlobMatcher.literalPrefix(of: expanded)) else { continue }
            let glob = GlobMatcher().match(expanded)
            result.errors += glob.errors
            for match in glob.matches {
                if Task.isCancelled {
                    result.status = .cancelled
                    break patterns
                }
                if excludes.contains(where: { fnmatch($0, match, 0) == 0 }) { continue }
                switch ItemBuilder.build(path: match, within: prefixReal, rule: rule, context: context, ledger: ledger) {
                case .item(let item): result.items.append(item)
                case .dropped(let reason): result.errors.append("\(match): \(reason)")
                case .filtered: break
                }
            }
        }
        result.items.sort { $0.size > $1.size }
        return result
    }
}
