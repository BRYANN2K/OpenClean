import Foundation
import RuleKit

public enum EntryOutcome: String, Codable, Sendable {
    case pending, deleted, quarantined, trashed, skipped, failed, restored, purged
}

public struct ManifestEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var originalPath: String
    /// Planned (while pending) or actual location of the stored copy.
    public var storedPath: String?
    public var size: Int64
    public var ruleID: String
    public var mode: DeleteMode
    public var outcome: EntryOutcome
    public var reason: String?

    public init(
        id: Int, originalPath: String, storedPath: String?, size: Int64, ruleID: String,
        mode: DeleteMode, outcome: EntryOutcome, reason: String?
    ) {
        self.id = id
        self.originalPath = originalPath
        self.storedPath = storedPath
        self.size = size
        self.ruleID = ruleID
        self.mode = mode
        self.outcome = outcome
        self.reason = reason
    }
}

public struct SessionManifest: Codable, Sendable, Equatable, Identifiable {
    public var schema: Int = 1
    public var id: String
    public var createdAt: Date
    public var purgedAt: Date?
    public var entries: [ManifestEntry]

    public init(id: String, createdAt: Date, purgedAt: Date? = nil, entries: [ManifestEntry] = []) {
        self.id = id
        self.createdAt = createdAt
        self.purgedAt = purgedAt
        self.entries = entries
    }

    public func bytes(_ outcomes: Set<EntryOutcome>) -> Int64 {
        entries.filter { outcomes.contains($0.outcome) }.reduce(0) { $0 + $1.size }
    }

    public var deletedBytes: Int64 { bytes([.deleted]) }
    public var quarantinedBytes: Int64 { bytes([.quarantined, .trashed]) }
    public var skippedEntries: [ManifestEntry] { entries.filter { $0.outcome == .skipped || $0.outcome == .failed } }

    /// Entries whose stored copy can be moved back (including ones a crash left pending).
    public var restorableEntries: [ManifestEntry] {
        entries.filter { [.quarantined, .trashed, .pending].contains($0.outcome) && $0.storedPath != nil }
    }
}

extension Date {
    /// Truncated to whole seconds so ISO-8601 manifests round-trip exactly.
    public var wholeSeconds: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
