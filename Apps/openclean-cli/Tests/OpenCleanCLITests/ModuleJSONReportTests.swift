import AppInventory
import Foundation
import SystemMonitor
import Testing

@testable import OpenCleanCLI
@testable import SpaceKit

/// Golden JSON for `apps`, `space` and `performance` (the `--json` contract). Re-record with
/// `OPENCLEAN_RECORD_GOLDEN=1 swift test --filter ModuleJSONReportTests` and review the diff.
struct ModuleJSONReportTests {
    static let date = JSONReportTests.date

    static func app(status: AppStatus = .removable, version: String? = "1.2", lastUsed: Date? = date) -> InstalledApp {
        InstalledApp(
            path: "/Users/t/Applications/Foo.app", name: "Foo", bundleID: "com.example.foo", version: version,
            size: 40_960, device: 1, inode: 2, modificationDate: date, ownerUID: 501, isRunning: false,
            isWritable: status == .removable, lastUsed: lastUsed, status: status)
    }

    static func leftover(_ path: String, _ kind: LeftoverKind, _ match: LeftoverMatch, _ scope: LeftoverScope = .user)
        -> Leftover
    {
        Leftover(
            path: path, kind: kind, match: match, scope: scope, size: scope == .user ? 2_048 : 512, device: 1,
            inode: 3, modificationDate: date, ownerUID: 501, isDirectory: true)
    }

    static func listing(status: AppStatus = .removable) -> AppListing {
        AppListing(
            app: app(status: status),
            leftovers: [
                leftover("/Users/t/Library/Caches/com.example.foo", .caches, .bundleID),
                leftover("/Users/t/Library/Application Support/Foo", .applicationSupport, .name),
                leftover("/Library/LaunchDaemons/com.example.foo.plist", .launchDaemons, .bundleID, .system),
            ])
    }

    @Test func appsJSONMatchesGolden() throws {
        let other = AppListing(
            app: InstalledApp(
                path: "/Applications/Utilities/Tool.app", name: "Tool", bundleID: nil, version: nil, size: 1_024,
                device: 1, inode: 4, modificationDate: Self.date, ownerUID: 0, isRunning: true, isWritable: false,
                lastUsed: nil, status: .noBundleID),
            leftovers: [])
        try Golden.check(try JSONReport.apps([Self.listing(), other]), named: "apps.json")
    }

    @Test func uninstallPlanChoosesBundleIDLeftoversByDefault() throws {
        let plan = UninstallPlan(listing: Self.listing(status: .needsAdministrator), includeNameMatches: false)
        #expect(plan.paths == ["/Users/t/Applications/Foo.app", "/Users/t/Library/Caches/com.example.foo"])
        #expect(plan.totalBytes == 40_960 + 2_048)
        #expect(plan.staying.map(\.kind) == [.applicationSupport, .launchDaemons])
        try Golden.check(try JSONReport.uninstallPlan(plan), named: "uninstall-plan.json")

        let all = UninstallPlan(listing: Self.listing(), includeNameMatches: true)
        #expect(all.chosen.map(\.kind) == [.caches, .applicationSupport])
        #expect(all.staying.map(\.isReportOnly) == [true])
    }

    @Test func largeFilesJSONMatchesGolden() throws {
        func file(_ name: String, _ size: Int64, opened: Date?) -> LargeFile {
            LargeFile(
                snapshot: FileSnapshot(
                    path: "/Users/t/Downloads/" + name, device: 1, inode: 1, modificationDate: Self.date,
                    isDirectory: false),
                scanRoot: "/Users/t", name: name, size: size, kind: FileKind(fileName: name), lastOpened: opened,
                modified: Self.date, isUserContent: false)
        }
        let files = [file("ubuntu.iso", 4_000_000_000, opened: Self.date), file("movie.mkv", 900_000_000, opened: nil)]
        let result = LargeFileResult(
            files: files, roots: ["/Users/t"], unreadable: ["/Users/t/Locked"], unreadableCount: 1, isComplete: true)
        let filter = LargeFileFilter(minimumSize: 500_000_000, notOpenedForDays: 90)
        try Golden.check(try JSONReport.largeFiles(result, files: files, filter: filter), named: "space-large.json")
    }

    @Test func duplicatesJSONMatchesGolden() throws {
        func file(_ path: String) -> DuplicateFile {
            DuplicateFile(
                snapshot: FileSnapshot(
                    path: path, device: 1, inode: 1, modificationDate: Self.date, isDirectory: false),
                scanRoot: "/Users/t/Downloads", name: (path as NSString).lastPathComponent, size: 2_002_944,
                created: Self.date, modified: Self.date, isUserContent: false)
        }
        let keep = "/Users/t/Pictures/photo.jpg"
        let group = DuplicateGroup(
            id: String(repeating: "ab", count: 32), logicalSize: 2_000_000,
            files: [file(keep), file("/Users/t/Downloads/photo.jpg")], suggestedKeep: keep)
        let result = DuplicateResult(
            groups: [group], roots: ["/Users/t/Downloads", "/Users/t/Pictures"], unreadable: [], unreadableCount: 0,
            unhashable: 1, isComplete: true)
        try Golden.check(try JSONReport.duplicates(result), named: "space-duplicates.json")
    }

    @Test func performanceJSONMatchesGolden() throws {
        func process(_ pid: Int32, _ cpu: Double, _ bytes: UInt64) -> ProcessUsage {
            ProcessUsage(pid: pid, uid: 501, name: "p\(pid)", path: nil, cpuPercent: cpu, residentBytes: bytes)
        }
        let groups = [
            ProcessGroup(
                id: "/Applications/Big.app", name: "Big", bundlePath: "/Applications/Big.app", mainPID: 10,
                processes: [process(10, 120.04, 3_000_000_000), process(11, 5.0, 1_000_000_000)], cpuPercent: 125.04,
                residentBytes: 4_000_000_000, canQuit: true),
            ProcessGroup(
                id: "pid:20", name: "node", bundlePath: nil, mainPID: nil, processes: [process(20, 60.26, 500_000_000)],
                cpuPercent: 60.26, residentBytes: 500_000_000, canQuit: false),
        ]
        let monitor = MonitorSnapshot(
            time: 1, cpu: 0.41234,
            memory: MemoryUsage(
                used: 12_000_000_000, total: 16_000_000_000, appMemory: 6_000_000_000, wired: 3_000_000_000,
                compressed: 3_000_000_000, pressure: .normal),
            disk: DiskSnapshot(available: 100_000_000_000, total: 500_000_000_000), groups: groups)
        let snapshot = PerformanceSnapshot(interval: 1, monitor: monitor, limit: 1)
        #expect(snapshot.topCPU.map(\.name) == ["Big"])
        try Golden.check(try JSONReport.performance(snapshot), named: "performance.json")

        // Without a previous sample there is no CPU figure: the key is omitted, not null.
        let first = PerformanceSnapshot(interval: 1, monitor: MonitorSnapshot(time: 0), limit: 5)
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(try JSONReport.performance(first).utf8)) as? [String: Any])
        #expect(json["cpuUsage"] == nil && json["memory"] == nil && json["disk"] == nil)
        #expect(json["schema"] as? Int == 1)
    }
}
