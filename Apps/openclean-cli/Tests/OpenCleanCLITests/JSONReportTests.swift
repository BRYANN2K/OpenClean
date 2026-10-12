import Foundation
import Quarantine
import RuleKit
import ScanEngine
import Testing

@testable import OpenCleanCLI

struct JSONReportTests {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func item(_ path: String, _ rule: String, _ size: Int64, reportOnly: Bool = false, hint: String? = nil)
        -> ScanItem
    {
        ScanItem(
            path: path, ruleID: rule, size: size, device: 1, inode: 1, modificationDate: date, ownerUID: 501,
            reportOnly: reportOnly, hint: hint)
    }

    static func scanFixture() -> ScanResult {
        let caches = Rule(
            id: "user.app-caches", name: "App caches", category: .user, explain: "x",
            paths: ["~/Library/Caches/*"], safety: .regenerable)
        let trash = Rule(
            id: "trash.user", name: "Trash", category: .trash, explain: "x", paths: ["~/.Trash/*"],
            safety: .review, requires: [.fullDiskAccess])
        let docker = Rule(
            id: "docker.disk-image", name: "Docker disk image", category: .developer, explain: "x",
            probe: "docker.disk-image", safety: .review)
        return ScanResult(
            rules: [
                RuleResult(
                    rule: caches,
                    items: [
                        item("/Users/t/Library/Caches/com.a", caches.id, 2_048),
                        item("/Users/t/Library/Caches/com.b", caches.id, 1_024),
                    ]),
                RuleResult(rule: trash, status: .needsFullDiskAccess),
                RuleResult(
                    rule: docker,
                    items: [
                        item(
                            "/Users/t/Docker.raw", docker.id, 4_096, reportOnly: true, hint: "Use docker system prune.")
                    ],
                    errors: ["something odd"]),
            ],
            isComplete: true, startedAt: date, finishedAt: date.addingTimeInterval(2))
    }

    static func historyFixture() -> [SessionListing] {
        let manifest = SessionManifest(
            id: "20270115-080000-abcd", createdAt: date, purgedAt: nil,
            entries: [
                ManifestEntry(
                    id: 0, originalPath: "/Users/t/Library/Caches/com.a", storedPath: nil, size: 2_048,
                    ruleID: "user.app-caches", mode: .immediate, outcome: .deleted, reason: nil),
                ManifestEntry(
                    id: 1, originalPath: "/Users/t/Downloads/x.dmg",
                    storedPath:
                        "/Users/t/Library/Application Support/OpenClean/Quarantine/20270115-080000-abcd/items/1/x.dmg",
                    size: 4_096, ruleID: "fixture.downloads", mode: .quarantine, outcome: .quarantined, reason: nil),
                ManifestEntry(
                    id: 2, originalPath: "/Users/t/Library/Caches/com.b", storedPath: nil, size: 1_024,
                    ruleID: "user.app-caches", mode: .immediate, outcome: .skipped, reason: "open in another app"),
            ])
        return [.ok(manifest), .damaged(id: "broken", created: date)]
    }

    @Test func scanJSONMatchesGolden() throws {
        try Golden.check(try JSONReport.scan(Self.scanFixture()), named: "scan.json")
    }

    @Test func scanJSONStructure() throws {
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(try JSONReport.scan(Self.scanFixture()).utf8)) as? [String: Any]
        )
        #expect(json["schema"] as? Int == 1)
        #expect(json["complete"] as? Bool == true)
        #expect(json["totalBytes"] as? Int == 3_072)
        let rules = try #require(json["rules"] as? [[String: Any]])
        #expect(rules.map { $0["id"] as? String } == ["user.app-caches", "trash.user", "docker.disk-image"])
        #expect(rules[1]["status"] as? String == "needs_full_disk_access")
        #expect(rules[2]["totalBytes"] as? Int == 0)
        let dockerItem = try #require((rules[2]["items"] as? [[String: Any]])?.first)
        #expect(dockerItem["reportOnly"] as? Bool == true)
        #expect(dockerItem["bytes"] as? Int == 4_096)
    }

    @Test func historyJSONMatchesGolden() throws {
        try Golden.check(try JSONReport.history(Self.historyFixture()), named: "history.json")
    }

    @Test func historyJSONStructure() throws {
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(try JSONReport.history(Self.historyFixture()).utf8))
                as? [String: Any])
        let sessions = try #require(json["sessions"] as? [[String: Any]])
        #expect(sessions.count == 2)
        #expect(sessions[0]["deletedBytes"] as? Int == 2_048)
        #expect(sessions[0]["quarantinedBytes"] as? Int == 4_096)
        #expect(sessions[0]["skippedCount"] as? Int == 1)
        #expect(sessions[0]["createdAt"] as? String == "2027-01-15T08:00:00Z")
        #expect(sessions[1]["damaged"] as? Bool == true)
    }

    @Test func statusStrings() {
        #expect(JSONReport.status(.scanned) == "scanned")
        #expect(JSONReport.status(.skippedAppRunning("com.x")) == "app_running:com.x")
        #expect(JSONReport.status(.cancelled) == "cancelled")
    }
}
