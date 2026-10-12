import Foundation
import Quarantine
import Testing

@testable import OpenCleanAppModel

struct CleanupStatsTests {
    func session(daysAgo: Int = 0, entries: [(Int64, EntryOutcome)]) -> SessionManifest {
        SessionManifest(
            id: UUID().uuidString,
            createdAt: Date(timeIntervalSince1970: 1_791_800_000 - TimeInterval(daysAgo * 86_400)),
            entries: entries.enumerated().map { index, entry in
                ManifestEntry(
                    id: index, originalPath: "/tmp/\(index)", storedPath: nil, size: entry.0, ruleID: "r",
                    mode: .immediate, outcome: entry.1, reason: nil)
            })
    }

    @Test func emptyHistoryIsZero() {
        let stats = CleanupStats(history: [])
        #expect(stats.cleanups == 0)
        #expect(stats.totalFreedBytes == 0)
        #expect(stats.lastCleanup == nil)
    }

    @Test func freedBytesCountPurgedButNotRestoredOrSkipped() {
        let manifest = session(entries: [
            (100, .deleted), (200, .quarantined), (300, .purged), (400, .restored), (500, .skipped),
        ])
        #expect(CleanupStats.freedBytes(manifest) == 600)
    }

    @Test func sessionsThatFreedNothingDontCount() {
        let stats = CleanupStats(history: [session(entries: [(100, .skipped)])])
        #expect(stats.cleanups == 0)
        #expect(stats.totalFreedBytes == 0)
    }

    @Test func totalsAndLastCleanup() {
        let older = session(daysAgo: 3, entries: [(1_000, .deleted)])
        let newer = session(daysAgo: 1, entries: [(4_000, .quarantined)])
        let stats = CleanupStats(history: [newer, older])
        #expect(stats.cleanups == 2)
        #expect(stats.totalFreedBytes == 5_000)
        #expect(stats.lastCleanup == newer.createdAt)
    }

}
