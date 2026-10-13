import Foundation
import Quarantine

/// Items a clean left in place, grouped by why, for the cleanup summary's details.
public struct SkippedItems: Equatable, Sendable {
    public struct Group: Equatable, Sendable, Identifiable {
        /// Why, in plain words ("Changed since the scan; an app may be using it.").
        public let explanation: String
        /// The items' original paths, in manifest order.
        public let paths: [String]
        public var id: String { explanation }
    }

    public let groups: [Group]
    /// True when scanning again could let at least one item be cleaned (it changed, was in use, ...).
    public let suggestsRescan: Bool

    public init(report: RemovalReport) {
        self.init(entries: report.skipped)
    }

    public init(entries: [ManifestEntry]) {
        var order: [String] = []
        var paths: [String: [String]] = [:]
        for entry in entries {
            guard let explanation = entry.plainSkipExplanation else { continue }
            if paths[explanation] == nil { order.append(explanation) }
            paths[explanation, default: []].append(entry.originalPath)
        }
        groups = order.map { Group(explanation: $0, paths: paths[$0] ?? []) }
        suggestsRescan = entries.contains(where: \.isWorthRescanning)
    }

    public var count: Int { groups.reduce(0) { $0 + $1.paths.count } }
    public var isEmpty: Bool { groups.isEmpty }

    /// "2 items were left in place", or "1 item was left in place".
    public var headline: String {
        "\(count) item\(count == 1 ? " was" : "s were") left in place"
    }

    /// One line under the headline: the reason when there is only one, otherwise a pointer to the details.
    public var summary: String {
        if groups.count == 1, let only = groups.first { return only.explanation }
        return "For different reasons; see the details."
    }
}
