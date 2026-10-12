import AppInventory
import Foundation
import OpenCleanKit
import RuleKit
import ScanEngine
import TestSupport
import Testing

@testable import OpenCleanAppModel

@MainActor
struct UninstallerModelTests {
    func makeModel(_ home: TempDirectory, running: Set<String> = []) -> UninstallerModel {
        let coordinator = OpenCleanCoordinator(
            home: home.path, environment: [:], registry: ProbeRegistry([]),
            processChecker: FakeProcessChecker(running: running), openFiles: FakeOpenFiles(),
            admin: FakeAdminExecutor(), fullDiskAccess: { .granted }, trash: { _ in nil })
        return UninstallerModel(coordinator: coordinator, lastUsed: nil, systemLibrary: home.path + "/SystemLibrary")
    }

    @discardableResult
    func makeApp(_ home: TempDirectory, _ name: String, id: String) throws -> String {
        let contents = try home.directory("Applications/\(name).app/Contents")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: contents + "/Info.plist"))
        try home.file("Applications/\(name).app/Contents/MacOS/app", bytes: 2_048)
        return home.path + "/Applications/\(name).app"
    }

    @Test func loadsSearchesSelectsAndUninstalls() async throws {
        let home = try TempDirectory()
        let foo = try makeApp(home, "Foo", id: "com.example.foo")
        try makeApp(home, "Bar", id: "com.example.bar")
        let byID = try home.directory("Library/Caches/com.example.foo")
        let byName = try home.directory("Library/Application Support/Foo")
        let model = makeModel(home)

        model.onAppear()
        await model.waitForLoad()
        #expect(model.phase == .list)
        #expect(model.apps.map(\.name) == ["Bar", "Foo"])
        model.searchText = "fo"
        #expect(model.filteredApps.map(\.name) == ["Foo"])

        let app = try #require(model.filteredApps.first)
        model.select(app)
        await model.waitForLeftovers()
        #expect(Set(model.leftovers.map(\.path)) == [byID, byName])
        // Bundle-id matches are ticked by default; name matches are not.
        #expect(model.selectedLeftovers == [byID])
        #expect(model.canUninstall)
        #expect(model.selectedBytes == app.size + (model.leftovers.first { $0.path == byID }?.size ?? 0))

        model.requestUninstall()
        #expect(model.isConfirmPresented)
        await model.uninstall()
        #expect(model.phase == .finished)
        #expect(model.appWasRemoved)
        #expect(FileStat.of(foo) == nil)
        #expect(FileStat.of(byID) == nil)
        #expect(FileStat.of(byName) != nil)

        model.done()
        await model.waitForLoad()
        #expect(model.phase == .list)
        #expect(model.apps.map(\.name) == ["Bar"])
        #expect(model.selectedApp == nil)
    }

    @Test func runningAppCannotBeUninstalled() async throws {
        let home = try TempDirectory()
        try makeApp(home, "Foo", id: "com.example.foo")
        let model = makeModel(home, running: ["com.example.foo"])
        model.load()
        await model.waitForLoad()
        model.select(try #require(model.apps.first))
        await model.waitForLeftovers()
        #expect(model.selectedAppIsRunning)
        #expect(!model.canUninstall)
        model.requestUninstall()
        #expect(!model.isConfirmPresented)
    }

    @Test func reportOnlyLeftoversCannotBeTicked() async throws {
        let home = try TempDirectory()
        try makeApp(home, "Foo", id: "com.example.foo")
        try home.file("SystemLibrary/LaunchDaemons/com.example.foo.plist")
        let model = makeModel(home)
        model.load()
        await model.waitForLoad()
        model.select(try #require(model.apps.first))
        await model.waitForLeftovers()
        let daemon = try #require(model.reportOnlyLeftovers.first)
        model.toggle(daemon)
        #expect(model.selectedLeftovers.isEmpty)
        #expect(model.leftoverGroups.isEmpty)
    }
}
