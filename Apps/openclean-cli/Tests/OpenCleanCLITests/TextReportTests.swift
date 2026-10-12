import Foundation
import OpenCleanKit
import RuleKit
import ScanEngine
import Testing

@testable import OpenCleanCLI

struct TextReportTests {
    @Test func planListsEachAdminPath() throws {
        let system = Rule(
            id: "system.logs", name: "System logs", category: .system, explain: "x",
            paths: ["/Library/Logs/*"], safety: .regenerable, requires: [.admin])
        let caches = Rule(
            id: "user.app-caches", name: "App caches", category: .user, explain: "x",
            paths: ["~/Library/Caches/*"], safety: .regenerable)
        let adminPath = "/Library/Logs/DiagnosticReports"
        let userPath = "/Users/t/Library/Caches/com.a"
        let result = ScanResult(
            rules: [
                RuleResult(rule: system, items: [JSONReportTests.item(adminPath, system.id, 2_048)]),
                RuleResult(rule: caches, items: [JSONReportTests.item(userPath, caches.id, 1_024)]),
            ],
            isComplete: true, startedAt: JSONReportTests.date, finishedAt: JSONReportTests.date)
        let plan = CleanupPlan(result: result, selectedPaths: [adminPath, userPath])

        let lines = TextReport.plan(plan, retentionDays: 7).components(separatedBy: "\n")
        let countLine = try #require(
            lines.firstIndex { $0.contains("1 system item(s) need your administrator password.") })
        #expect(lines[countLine + 1] == "    \(adminPath)")
        #expect(!lines.contains { $0.hasPrefix("    ") && $0.contains(userPath) })
    }
}
