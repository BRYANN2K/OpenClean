import Foundation
import ProcessKit
import RuleKit
import TestSupport
import Testing

@testable import AppInventory

struct AppInventoryTests {
    @Test func listsAppsWithMetadataAndStatus() async throws {
        let home = try TempDirectory()
        let system = try TempDirectory()
        let foo = try FakeApps.make(
            home, "Applications/Foo.app", id: "com.example.foo", bundleName: "Foo Pro", version: "2.1")
        try FakeApps.make(home, "Applications/Apple Thing.app", id: "com.apple.thing")
        try FakeApps.make(home, "Applications/NoID.app", id: nil)
        try FakeApps.make(home, "Applications/OpenClean.app", id: InstalledApp.openCleanBundleID)
        try home.directory("Applications/Not An App")
        try home.symlink("Applications/Link.app", to: foo)
        try FakeApps.make(system, "Utilities/Util.app", id: "com.example.util")

        let lastUsed = Date(timeIntervalSince1970: 1_700_000_000)
        let inventory = AppInventory(
            folders: [
                ApplicationFolder(path: home.path + "/Applications", allowsUninstall: true),
                ApplicationFolder(path: system.path + "/Utilities", allowsUninstall: false),
                ApplicationFolder(path: system.path + "/Missing", allowsUninstall: true),
            ],
            processChecker: FakeProcessChecker(running: ["com.example.foo"]),
            lastUsed: FixedLastUsed(dates: [foo: lastUsed]))
        let apps = await inventory.scan()

        #expect(apps.map(\.name) == ["Apple Thing", "Foo", "NoID", "OpenClean", "Util"])
        let app = try #require(apps.first { $0.name == "Foo" })
        #expect(app.path == foo)
        #expect(app.bundleID == "com.example.foo")
        #expect(app.bundleName == "Foo Pro")
        #expect(app.matchNames == ["Foo", "Foo Pro"])
        #expect(app.version == "2.1")
        #expect(app.size >= 4_096)
        #expect(app.isRunning)
        #expect(app.isWritable)
        #expect(app.lastUsed == lastUsed)
        #expect(app.ownerUID == getuid())
        #expect(app.status == .removable)

        let status = Dictionary(uniqueKeysWithValues: apps.map { ($0.name, $0.status) })
        #expect(status["Apple Thing"] == .appleApp)
        #expect(status["NoID"] == .noBundleID)
        #expect(status["OpenClean"] == .openClean)
        #expect(status["Util"] == .listOnly)
        #expect(apps.allSatisfy { $0.name != "Link" && $0.name != "Not An App" })
    }

    @Test func protectedPathIsMarkedAsOpenClean() async throws {
        let home = try TempDirectory()
        let mine = try FakeApps.make(home, "Applications/Renamed.app", id: "com.example.renamed")
        let apps = await AppInventory(
            folders: [ApplicationFolder(path: home.path + "/Applications", allowsUninstall: true)],
            processChecker: FakeProcessChecker(), lastUsed: nil, protectedPaths: [mine]
        ).scan()
        #expect(apps.map(\.status) == [.openClean])
    }

    @Test func unwritableAppNeedsAdministrator() async throws {
        let home = try TempDirectory()
        let folder = try home.directory("Applications")
        try FakeApps.make(home, "Applications/Locked.app", id: "com.example.locked")
        try setPermissions(folder, 0o555)
        defer { try? setPermissions(folder, 0o755) }
        let apps = await AppInventory(
            folders: [ApplicationFolder(path: folder, allowsUninstall: true)],
            processChecker: FakeProcessChecker(), lastUsed: nil
        ).scan()
        #expect(apps.map(\.status) == [.needsAdministrator])
        #expect(apps.first?.isWritable == false)
    }

    @Test func reportsProgress() async throws {
        let home = try TempDirectory()
        try FakeApps.make(home, "Applications/A.app", id: "com.example.a")
        try FakeApps.make(home, "Applications/B.app", id: "com.example.b")
        let (stream, continuation) = AsyncStream.makeStream(of: AppInventoryProgress.self)
        let inventory = AppInventory(
            folders: [ApplicationFolder(path: home.path + "/Applications", allowsUninstall: true)],
            processChecker: FakeProcessChecker(), lastUsed: nil)
        async let apps = inventory.scan(progress: continuation)
        var updates: [AppInventoryProgress] = []
        for await update in stream { updates.append(update) }
        #expect(await apps.count == 2)
        #expect(updates.first == AppInventoryProgress(finished: 0, total: 2))
        #expect(updates.last == AppInventoryProgress(finished: 2, total: 2))
    }

    @Test func parsesBatchedMdlsOutput() {
        let paths = ["/A.app", "/B.app", "/C.app"]
        let data = Data("2026-10-08 11:57:12 +0000\0(null)\02026-10-12 07:40:50 +0000".utf8)
        let dates = MdlsLastUsedProvider.parse(data, paths: paths)
        #expect(dates.count == 2)
        #expect(dates["/A.app"] == ISO8601DateFormatter().date(from: "2026-10-08T11:57:12Z"))
        #expect(dates["/B.app"] == nil)
        // A count mismatch can't be attributed safely.
        #expect(MdlsLastUsedProvider.parse(Data("(null)".utf8), paths: paths).isEmpty)
    }

    @Test func mdlsFailureMeansNoDates() {
        let runner = FakeCommandRunner()
        #expect(MdlsLastUsedProvider(runner: runner).lastUsedDates(for: ["/A.app"]).isEmpty)
        runner.respond("/usr/bin/mdls -raw -name kMDItemLastUsedDate /A.app", stdout: "2026-10-08 11:57:12 +0000")
        #expect(MdlsLastUsedProvider(runner: runner).lastUsedDates(for: ["/A.app"]).count == 1)
    }
}
