import AppInventory
import Foundation
import Quarantine
import RuleKit
import ScanEngine
import TestSupport
import Testing

@testable import OpenCleanKit

struct CoordinatorUninstallerTests {
    func coordinator(_ home: TempDirectory, running: Set<String> = []) -> OpenCleanCoordinator {
        OpenCleanCoordinator(
            home: home.path, environment: [:], registry: ProbeRegistry([]),
            processChecker: FakeProcessChecker(running: running), openFiles: FakeOpenFiles(),
            admin: FakeAdminExecutor(), fullDiskAccess: { .granted }, trash: { _ in nil })
    }

    func makeApp(_ home: TempDirectory, _ relative: String, id: String) throws -> String {
        let bundle = try home.directory(relative + "/Contents")
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": "3.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: bundle + "/Info.plist"))
        try home.file(relative + "/Contents/MacOS/app", bytes: 4_096)
        return home.path + "/" + relative
    }

    @Test func pretendHomeOnlyListsItsOwnApplicationsFolder() throws {
        let home = try TempDirectory()
        #expect(
            coordinator(home).applicationFolders == [
                ApplicationFolder(path: home.path + "/Applications", allowsUninstall: true)
            ])
    }

    @Test func listsFindsLeftoversUninstallsAndRestores() async throws {
        let home = try TempDirectory()
        let system = try TempDirectory()
        let app = try makeApp(home, "Applications/Foo.app", id: "com.example.foo")
        let support = try home.directory("Library/Application Support/com.example.foo")
        try home.file("Library/Application Support/com.example.foo/db", bytes: 1_024)
        let named = try home.directory("Library/Caches/Foo")
        try system.file("Library/LaunchDaemons/com.example.foo.plist")
        let subject = coordinator(home)

        let apps = await subject.installedApps(lastUsed: nil)
        let foo = try #require(apps.first)
        #expect(apps.count == 1)
        #expect(foo.status == .removable)
        #expect(foo.version == "3.0")

        let leftovers = subject.leftovers(for: foo, systemLibrary: system.path + "/Library")
        #expect(
            Set(leftovers.map(\.path)) == [
                support, named, system.path + "/Library/LaunchDaemons/com.example.foo.plist",
            ])
        #expect(leftovers.filter(\.isReportOnly).count == 1)

        // The report-only system item is ignored; the name match is included because it was passed.
        guard case .finished(let report) = try subject.uninstall(foo, leftovers: leftovers) else {
            Issue.record("expected the uninstall to finish")
            return
        }
        #expect(
            report.manifest.entries.map(\.originalPath) == [app] + leftovers.filter { !$0.isReportOnly }.map(\.path))
        #expect(report.manifest.entries.allSatisfy { $0.outcome == .quarantined })
        #expect(FileStat.of(app) == nil)
        #expect(FileStat.of(system.path + "/Library/LaunchDaemons/com.example.foo.plist") != nil)
        #expect(subject.history().count == 1)

        let restored = try subject.restore(sessionID: report.manifest.id, onConflict: .skip)
        #expect(restored.skipped.isEmpty)
        #expect(FileStat.of(app + "/Contents/Info.plist") != nil)
        #expect(FileStat.of(support + "/db") != nil)
    }

    @Test func refusesNonRemovableAndRunningApps() async throws {
        let home = try TempDirectory()
        let app = try makeApp(home, "Applications/Foo.app", id: "com.example.foo")
        try makeApp(home, "Applications/Apple.app", id: "com.apple.thing")
        let subject = coordinator(home, running: ["com.example.foo"])
        let apps = await subject.installedApps(lastUsed: nil)

        let apple = try #require(apps.first { $0.bundleID == "com.apple.thing" })
        guard case .refused(.appleApp) = try subject.uninstall(apple, leftovers: []) else {
            Issue.record("Apple apps must be refused")
            return
        }
        let foo = try #require(apps.first { $0.bundleID == "com.example.foo" })
        #expect(foo.isRunning)
        guard case .refused(.skipped(.appRunning)) = try subject.uninstall(foo, leftovers: []) else {
            Issue.record("running apps must be refused")
            return
        }
        #expect(FileStat.of(app) != nil)
        #expect(subject.history().isEmpty)
    }

    @Test func uninstallsAnAppThatNeedsAdministratorWithOnePromptAndRestores() async throws {
        let home = try TempDirectory()
        let app = try makeApp(home, "Applications/Foo.app", id: "com.example.foo")
        let support = try home.directory("Library/Caches/com.example.foo")
        let applications = home.path + "/Applications"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: applications)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: applications) }
        // The fake stands in for root by making the folder writable, then runs the real mv && chown text.
        let admin = FakeAdminExecutor(runForReal: true) { _ in
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: applications)
        }
        let subject = OpenCleanCoordinator(
            home: home.path, environment: [:], registry: ProbeRegistry([]), processChecker: FakeProcessChecker(),
            openFiles: FakeOpenFiles(), admin: admin, fullDiskAccess: { .granted }, trash: { _ in nil })

        let foo = try #require(await subject.installedApps(lastUsed: nil).first)
        #expect(foo.status == .needsAdministrator)
        #expect(foo.status.isRemovable && foo.status.requiresAdministrator)
        let leftovers = subject.leftovers(for: foo, systemLibrary: home.path + "/SystemLibrary")
        guard case .finished(let report) = try subject.uninstall(foo, leftovers: leftovers) else {
            Issue.record("expected the uninstall to finish")
            return
        }
        #expect(admin.bundleMoves.map(\.source) == [app])
        #expect(admin.commands.count == 1)
        #expect(report.manifest.entries.map(\.originalPath) == [app, support])
        #expect(report.manifest.entries.allSatisfy { $0.outcome == .quarantined })
        #expect(FileStat.of(app) == nil)

        let restored = try subject.restore(sessionID: report.manifest.id, onConflict: .skip)
        #expect(restored.skipped.isEmpty)
        #expect(FileStat.of(app + "/Contents/Info.plist") != nil)
        #expect(FileStat.of(app)?.ownerUID == getuid())
    }
}
