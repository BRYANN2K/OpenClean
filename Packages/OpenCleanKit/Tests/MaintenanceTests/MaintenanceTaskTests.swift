import Foundation
import Privilege
import TestSupport
import Testing

@testable import Maintenance

struct MaintenanceTaskTests {
    @Test func periodicIsHiddenWhenTheBinaryIsMissing() {
        let present: Set<String> = [
            "/usr/bin/dscacheutil", "/usr/bin/killall", "/usr/bin/mdutil", "/usr/bin/tmutil",
            MaintenanceTask.lsregister,
        ]
        let tasks = MaintenanceTask.available { present.contains($0) }
        #expect(!tasks.contains(.runPeriodicScripts))
        #expect(tasks == [.flushDNSCache, .reindexSpotlight, .rebuildLaunchServices, .thinLocalSnapshots])
        #expect(MaintenanceTask.available { _ in true } == MaintenanceTask.allCases)
        #expect(MaintenanceTask.available { _ in false }.isEmpty)
    }

    @Test func adminTasksMapOntoTheAllowList() {
        #expect(MaintenanceTask.flushDNSCache.adminCommand == .flushDNSCache)
        #expect(MaintenanceTask.reindexSpotlight.adminCommand == .reindexSpotlight)
        #expect(MaintenanceTask.runPeriodicScripts.adminCommand == .runPeriodicScripts)
        #expect(MaintenanceTask.thinLocalSnapshots.adminCommand == .thinLocalSnapshots)
        #expect(!MaintenanceTask.rebuildLaunchServices.needsAdmin)
        #expect(MaintenanceTask.allCases.allSatisfy { !$0.explanation.isEmpty && !$0.title.isEmpty })
        #expect(MaintenanceTask(rawValue: "purge") == nil, "freeing purgeable RAM is deliberately not offered")
    }

    @Test func adminTaskGoesThroughTheTypedExecutorOnly() {
        let admin = FakeMaintenanceAdminExecutor()
        let runner = FakeCommandRunner()
        let tasks = MaintenanceRunner(runner: runner, admin: admin)
        #expect(tasks.run(.flushDNSCache) == .succeeded)
        #expect(tasks.run(.thinLocalSnapshots) == .succeeded)
        #expect(admin.commands == [.flushDNSCache, .thinLocalSnapshots])
        #expect(runner.calls.isEmpty)

        #expect(
            MaintenanceRunner(runner: runner, admin: FakeMaintenanceAdminExecutor(outcome: .cancelled)).run(
                .reindexSpotlight) == .cancelled)
        #expect(
            MaintenanceRunner(runner: runner, admin: FakeMaintenanceAdminExecutor(outcome: .failed("x"))).run(
                .reindexSpotlight)
                == .failed("x"))
    }

    @Test func userTaskRunsTheExactCommandAndChecksExitStatus() {
        let admin = FakeMaintenanceAdminExecutor()
        let runner = FakeCommandRunner()
        let line = MaintenanceTask.lsregister + " -kill -r -domain local -domain system -domain user"
        #expect(MaintenanceRunner(runner: runner, admin: admin).run(.rebuildLaunchServices).isFailure)
        runner.respond(line, status: 0)
        #expect(MaintenanceRunner(runner: runner, admin: admin).run(.rebuildLaunchServices) == .succeeded)
        #expect(
            runner.calls.last == [
                MaintenanceTask.lsregister, "-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user",
            ])
        runner.respond(line, status: 2, stderr: "")
        #expect(MaintenanceRunner(runner: runner, admin: admin).run(.rebuildLaunchServices) == .failed("exit status 2"))
        #expect(admin.commands.isEmpty)
    }
}

struct MaintenanceHistoryTests {
    @Test func recordsLastRunAndIgnoresCancellations() throws {
        let dir = try TempDirectory()
        let store = MaintenanceHistoryStore(url: dir.url.appendingPathComponent("support/maintenance.json"))
        #expect(store.load().isEmpty)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try store.record(.flushDNSCache, outcome: .succeeded, at: date)
        try store.record(.reindexSpotlight, outcome: .failed("x"), at: date)
        try store.record(.thinLocalSnapshots, outcome: .cancelled, at: date)
        let records = store.load()
        #expect(records[.flushDNSCache] == MaintenanceRecord(date: date, succeeded: true))
        #expect(records[.reindexSpotlight] == MaintenanceRecord(date: date, succeeded: false))
        #expect(records[.thinLocalSnapshots] == nil)
    }

    @Test func damagedOrForeignEntriesAreIgnored() throws {
        let dir = try TempDirectory()
        let url = try URL(fileURLWithPath: dir.file("maintenance.json"))
        try Data("{ not json".utf8).write(to: url)
        #expect(MaintenanceHistoryStore(url: url).load().isEmpty)
        try Data(
            #"{"purge":{"date":"2027-01-15T08:00:00Z","succeeded":true},"flushDNSCache":{"date":"2027-01-15T08:00:00Z","succeeded":true}}"#
                .utf8
        )
        .write(to: url)
        #expect(Array(MaintenanceHistoryStore(url: url).load().keys) == [.flushDNSCache])
    }
}

extension MaintenanceOutcome {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
