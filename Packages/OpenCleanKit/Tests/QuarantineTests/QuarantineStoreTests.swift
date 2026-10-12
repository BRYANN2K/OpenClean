import Foundation
import RuleKit
import Testing
import TestSupport
@testable import Quarantine

struct QuarantineStoreTests {
    @Test func createSessionMakesItemsDirectoryAndManifest() throws {
        let dir = try TempDirectory()
        let store = QuarantineStore(root: dir.url.appendingPathComponent("Quarantine"))
        let session = try store.createSession(now: Date(timeIntervalSince1970: 1_800_000_000.75))
        #expect(FileStat.of(store.itemsDirectory(session.id).path)?.isDirectory == true)
        #expect(session.createdAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try store.read(id: session.id) == session)
        #expect(session.id.range(of: #"^\d{8}-\d{6}-[0-9a-f]{4}$"#, options: .regularExpression) != nil)
    }

    @Test func roundTripsEntries() throws {
        let dir = try TempDirectory()
        let store = QuarantineStore(root: dir.url)
        var session = try store.createSession()
        session.entries = [
            ManifestEntry(
                id: 0, originalPath: "/a", storedPath: nil, size: 10, ruleID: "r", mode: .immediate,
                outcome: .deleted, reason: nil),
            ManifestEntry(
                id: 1, originalPath: "/b", storedPath: "/q/1/b", size: 20, ruleID: "r", mode: .quarantine,
                outcome: .quarantined, reason: nil),
            ManifestEntry(
                id: 2, originalPath: "/c", storedPath: nil, size: 30, ruleID: "r", mode: .immediate,
                outcome: .skipped, reason: "in use"),
        ]
        try store.write(session)
        let loaded = try store.read(id: session.id)
        #expect(loaded == session)
        #expect(loaded.deletedBytes == 10)
        #expect(loaded.quarantinedBytes == 20)
        #expect(loaded.skippedEntries.map(\.originalPath) == ["/c"])
        #expect(loaded.restorableEntries.map(\.originalPath) == ["/b"])
    }

    @Test func listsNewestFirstAndFlagsDamagedSessions() throws {
        let dir = try TempDirectory()
        let store = QuarantineStore(root: dir.url)
        let older = try store.createSession(now: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = try store.createSession(now: Date(timeIntervalSince1970: 1_800_000_000))
        try FileManager.default.createDirectory(at: store.sessionDirectory("broken"), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.sessionDirectory("broken").appendingPathComponent("manifest.json"))

        let listings = store.listSessions()
        let okIDs = listings.compactMap { listing -> String? in
            if case .ok(let manifest) = listing { return manifest.id }
            return nil
        }
        let damagedIDs = listings.compactMap { listing -> String? in
            if case .damaged(let id, _) = listing { return id }
            return nil
        }
        #expect(okIDs == [newer.id, older.id])
        #expect(damagedIDs == ["broken"])
    }

    @Test func readingUnknownSessionThrows() throws {
        let dir = try TempDirectory()
        #expect(throws: QuarantineError.sessionNotFound("nope")) {
            try QuarantineStore(root: dir.url).read(id: "nope")
        }
    }
}
