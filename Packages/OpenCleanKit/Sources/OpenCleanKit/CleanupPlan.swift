import Foundation
import Quarantine
import RuleKit
import ScanEngine

/// What will happen if the user confirms: selected, removable items grouped by delete mode.
public struct CleanupPlan: Sendable {
    public let requests: [RemovalRequest]

    public init(result: ScanResult, selectedPaths: Set<String>) {
        requests = result.rules.flatMap { ruleResult in
            ruleResult.items
                .filter { !$0.reportOnly && selectedPaths.contains($0.path) }
                .map { RemovalRequest(item: $0, rule: ruleResult.rule) }
        }
    }

    public var isEmpty: Bool { requests.isEmpty }
    public var itemCount: Int { requests.count }
    public var immediateRequests: [RemovalRequest] { requests.filter { $0.rule.effectiveDeleteMode == .immediate } }
    public var quarantineRequests: [RemovalRequest] { requests.filter { $0.rule.effectiveDeleteMode == .quarantine } }
    public var adminRequests: [RemovalRequest] { requests.filter { $0.rule.needs(.admin) } }
    public var immediateBytes: Int64 { immediateRequests.reduce(0) { $0 + $1.item.size } }
    public var quarantineBytes: Int64 { quarantineRequests.reduce(0) { $0 + $1.item.size } }
    public var totalBytes: Int64 { immediateBytes + quarantineBytes }
}

public enum DefaultSelection {
    /// Regenerable items from fully scanned rules. Review and caution items start unselected.
    public static func paths(in result: ScanResult) -> Set<String> {
        Set(
            result.rules
                .filter { $0.rule.safety.isSelectedByDefault && $0.status == .scanned }
                .flatMap(\.items)
                .filter { !$0.reportOnly }
                .map(\.path))
    }
}
