import Foundation
import Quarantine

/// Totals derived entirely from cleanup history. Nothing extra is stored or sent anywhere.
public struct CleanupStats: Equatable, Sendable {
    public let cleanups: Int
    public let totalFreedBytes: Int64
    public let lastCleanup: Date?

    public init(history: [SessionManifest]) {
        let counted = history.filter { Self.freedBytes($0) > 0 && !Self.isMaintenance($0) }
        cleanups = counted.count
        totalFreedBytes = counted.reduce(0) { $0 + Self.freedBytes($1) }
        lastCleanup = counted.map(\.createdAt).max()
    }

    /// Sessions that keep something for undo rather than clean: the previous version after an update and
    /// launch agents removed in Performance. They're listed in History but don't count as cleanups.
    static let maintenanceRuleIDs: Set<String> = ["update.previous-version", "performance.launch-agent"]

    static func isMaintenance(_ manifest: SessionManifest) -> Bool {
        !manifest.entries.isEmpty && manifest.entries.allSatisfy { maintenanceRuleIDs.contains($0.ruleID) }
    }

    /// Bytes a session actually freed: deleted, quarantined (or trashed) and later purged.
    /// Items that were restored again don't count.
    public static func freedBytes(_ manifest: SessionManifest) -> Int64 {
        manifest.bytes([.deleted, .quarantined, .trashed, .purged])
    }
}

/// Free space on the volume holding the user's home.
public struct DiskSpace: Equatable, Sendable {
    public let available: Int64
    public let total: Int64

    public init(available: Int64, total: Int64) {
        self.available = available
        self.total = total
    }

    public var freeFraction: Double { total > 0 ? Double(available) / Double(total) : 0 }

    public static func volume(containing url: URL) -> DiskSpace? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys),
            let available = values.volumeAvailableCapacityForImportantUsage,
            let total = values.volumeTotalCapacity
        else { return nil }
        return DiskSpace(available: available, total: Int64(total))
    }
}
