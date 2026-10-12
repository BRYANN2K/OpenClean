import Foundation
import RuleKit

/// Deletes stored copies of sessions older than the retention period. Manifests are kept for History.
public struct Purger: Sendable {
    public static let retentionRange = 1...90
    let store: QuarantineStore

    public init(store: QuarantineStore) {
        self.store = store
    }

    @discardableResult
    public func purge(retentionDays: Int, now: Date = .now) -> [String] {
        let days = min(max(retentionDays, Self.retentionRange.lowerBound), Self.retentionRange.upperBound)
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var purged: [String] = []

        for listing in store.listSessions() {
            switch listing {
            case .ok(var manifest) where manifest.purgedAt == nil && manifest.createdAt < cutoff:
                let items = store.itemsDirectory(manifest.id)
                guard removeContained(items) else { continue }
                for index in manifest.entries.indices
                where [.quarantined, .pending].contains(manifest.entries[index].outcome)
                    && manifest.entries[index].storedPath.map({ pathIsWithin($0, items.path) }) == true
                {
                    manifest.entries[index].outcome = .purged
                }
                manifest.purgedAt = now.wholeSeconds
                if (try? store.write(manifest)) != nil { purged.append(manifest.id) }
            case .damaged(let id, let created) where (created ?? .distantFuture) < cutoff:
                let items = store.itemsDirectory(id)
                if FileStat.of(items.path) != nil, removeContained(items) {
                    purged.append(id)
                }
            default:
                break
            }
        }
        return purged
    }

    /// Removes `items` only if it sits strictly inside the store root. True when it no longer exists.
    private func removeContained(_ items: URL) -> Bool {
        guard pathIsWithin(items.path, store.root.path), items.path != store.root.path,
            !hasNonCanonicalComponent(items.path)
        else { return false }
        if FileStat.of(items.path) == nil { return true }
        try? FileManager.default.removeItem(at: items)
        return FileStat.of(items.path) == nil
    }
}
