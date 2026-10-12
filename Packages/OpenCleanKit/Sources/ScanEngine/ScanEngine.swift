import Foundation
import RuleKit

/// Runs every rule concurrently and returns results in the order the rules were given.
public struct ScanEngine: Sendable {
    public let registry: ProbeRegistry

    public init(registry: ProbeRegistry = ProbeRegistry([])) {
        self.registry = registry
    }

    /// Scans `rules`. Yields one progress event per finished rule and finishes `progress`.
    /// Cancelling the calling task returns partial results with `isComplete == false`.
    public func scan(
        _ rules: [Rule], context: ScanContext,
        progress: AsyncStream<ScanProgress>.Continuation? = nil
    ) async -> ScanResult {
        let started = Date()
        let ledger = HardLinkLedger()
        var slots = [RuleResult?](repeating: nil, count: rules.count)
        var finished = 0

        await withTaskGroup(of: (Int, RuleResult).self) { group in
            for (index, rule) in rules.enumerated() {
                group.addTask {
                    (index, await self.scanOne(rule, context: context, ledger: ledger))
                }
            }
            for await (index, result) in group {
                slots[index] = result
                finished += 1
                progress?.yield(ScanProgress(ruleID: result.rule.id, finished: finished, total: rules.count))
            }
        }
        progress?.finish()

        var results = slots.compactMap { $0 }
        Self.removeOverlaps(&results)
        let complete = !Task.isCancelled && !results.contains { $0.status == .cancelled }
        return ScanResult(rules: results, isComplete: complete, startedAt: started, finishedAt: Date())
    }

    func scanOne(_ rule: Rule, context: ScanContext, ledger: HardLinkLedger) async -> RuleResult {
        if Task.isCancelled { return RuleResult(rule: rule, status: .cancelled) }
        guard let probeID = rule.probe else {
            return PathRuleScanner().scan(rule, context: context, ledger: ledger)
        }

        var result = RuleResult(rule: rule)
        if let blocked = Gate.check(rule, context) {
            result.status = blocked
            return result
        }
        guard let probe = registry.probe(for: probeID) else {
            result.errors.append("unknown probe \(probeID)")
            return result
        }
        do {
            for finding in try await probe.scan(context) {
                if finding.reportOnly && FileStat.of(finding.path) == nil {
                    result.items.append(.virtual(path: finding.path, ruleID: rule.id, hint: finding.hint))
                    continue
                }
                switch ItemBuilder.build(
                    path: finding.path, within: nil, rule: rule, context: context, ledger: ledger,
                    reportOnly: finding.reportOnly, hint: finding.hint)
                {
                case .item(let item): result.items.append(item)
                case .dropped(let reason): result.errors.append("\(finding.path): \(reason)")
                case .filtered: break
                }
            }
        } catch {
            if Task.isCancelled { result.status = .cancelled }
            result.errors.append("probe \(probeID) failed: \(error)")
        }
        result.items.sort { $0.size > $1.size }
        return result
    }

    /// Keeps each path once: an item is dropped when an earlier rule already claimed it,
    /// one of its ancestors, or one of its descendants. Report-only items are always kept and claim
    /// their path first (regardless of rule order), so nothing removable equals, contains or sits inside them.
    static func removeOverlaps(_ results: inout [RuleResult]) {
        var claimed = Set<String>()
        var claimedAncestors = Set<String>()
        for item in results.flatMap(\.items) where item.reportOnly && item.path.hasPrefix("/") {
            claimed.insert(item.path)
            claimedAncestors.formUnion(ancestorPaths(of: item.path))
        }
        for index in results.indices {
            results[index].items = results[index].items.filter { item in
                if item.reportOnly { return true }
                let ancestors = ancestorPaths(of: item.path)
                if claimed.contains(item.path) || claimedAncestors.contains(item.path)
                    || ancestors.contains(where: claimed.contains)
                {
                    return false
                }
                claimed.insert(item.path)
                claimedAncestors.formUnion(ancestors)
                return true
            }
        }
    }

    static func ancestorPaths(of path: String) -> [String] {
        var result: [String] = []
        var current = (path as NSString).deletingLastPathComponent
        while current.count > 1 {
            result.append(current)
            current = (current as NSString).deletingLastPathComponent
        }
        return result
    }
}
