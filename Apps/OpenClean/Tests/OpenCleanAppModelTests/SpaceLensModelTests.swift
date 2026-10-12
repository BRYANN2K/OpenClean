import Foundation
import OpenCleanKit
import Quarantine
import ScanEngine
import SpaceKit
import TestSupport
import Testing
import os

@testable import OpenCleanAppModel

@MainActor
struct SpaceLensModelTests {
    final class TrashLog: Sendable {
        let moved = OSAllocatedUnfairLock(initialState: [String]())
        var paths: [String] { moved.withLock { $0 } }
    }

    func makeModel(_ home: TempDirectory, log: TrashLog = TrashLog()) -> SpaceLensModel {
        let coordinator = OpenCleanCoordinator(
            home: home.path, environment: [:], registry: ProbeRegistry([]), processChecker: FakeProcessChecker(),
            openFiles: FakeOpenFiles(), admin: FakeAdminExecutor(), fullDiskAccess: { .granted },
            trash: { path in
                log.moved.withLock { $0.append(path) }
                return nil
            })
        return SpaceLensModel(coordinator: coordinator)
    }

    func pattern(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7) }) }

    @Test func mapScanSelectsNothingAndNavigates() async throws {
        let home = try TempDirectory()
        try home.file("Movies/Project/render.mov", bytes: 300_000)
        try home.file("Downloads/a.zip", bytes: 10_000)
        let model = makeModel(home)
        #expect(model.mapRoot == home.path)
        model.startMapScan()
        await model.waitForScan(.map)
        #expect(model.mapPhase == .results)
        #expect(model.selection.isEmpty)
        #expect(model.focusedNode?.id == home.path)

        model.focus(on: home.path + "/Movies")
        #expect(model.breadcrumb.map(\.name) == [(home.path as NSString).lastPathComponent, "Movies"])
        model.focus(on: home.path + "/Movies/Project/render.mov")  // files can't be focused
        #expect(model.focusedNode?.name == "Movies")
        model.goUp()
        #expect(model.focusedNode?.id == home.path)
    }

    @Test func trashingFromTheMapUpdatesSizes() async throws {
        let home = try TempDirectory()
        let render = try home.file("Movies/render.mov", bytes: 300_000)
        let log = TrashLog()
        let model = makeModel(home, log: log)
        model.startMapScan()
        await model.waitForScan(.map)
        let before = try #require(model.mapResult?.root.size)
        let node = try #require(model.mapResult?.root.node(withID: render))
        model.toggle(try #require(model.candidate(for: node)))
        #expect(model.selectedBytes == node.size)
        model.requestTrash()
        #expect(model.isConfirmPresented)
        await model.confirmTrash()
        #expect(log.paths == [render])
        #expect(model.mapResult?.root.size == before - node.size)
        #expect(model.selection.isEmpty)
        #expect(model.lastReport?.trashed.count == 1)
        #expect(!model.isConfirmPresented)
    }

    @Test func protectedItemsCannotBeSelected() async throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/big.bin", bytes: 100_000)
        try home.file("Documents/Projects/a.txt", bytes: 100_000)
        let model = makeModel(home)
        model.startMapScan()
        await model.waitForScan(.map)
        let library = try #require(model.mapResult?.root.node(withID: home.path + "/Library"))
        let projects = try #require(model.mapResult?.root.node(withID: home.path + "/Documents/Projects"))
        #expect(model.protection(for: library.id, isDirectory: true) != nil)
        model.toggle(try #require(model.candidate(for: library)))
        model.toggle(try #require(model.candidate(for: projects)))
        #expect(model.selection.isEmpty)
        let root = try #require(model.mapResult?.root)
        #expect(model.candidate(for: root) == nil)
    }

    @Test func largeFilesFilterWithoutRescanning() async throws {
        let home = try TempDirectory()
        try home.file("Downloads/big.dmg", bytes: 60_000_000)
        try home.file("Documents/movie.mp4", bytes: 60_000_000)
        let model = makeModel(home)
        model.tab = .large
        model.startLargeScan()
        await model.waitForScan(.large)
        #expect(model.largeResult?.files.map(\.name) == ["big.dmg"])
        #expect(model.visibleLargeFiles.isEmpty)  // default threshold is 100 MB
        model.largeFilter.minimumSize = 50_000_000
        #expect(model.largeGroups.map(\.kind) == [.installer])
        #expect(model.selection.isEmpty)

        model.setIncludeUserContent(true)
        await model.waitForScan(.large)
        #expect(Set(model.visibleLargeFiles.map(\.name)) == ["big.dmg", "movie.mp4"])
    }

    @Test func duplicatesKeepAtLeastOneCopy() async throws {
        let home = try TempDirectory()
        for path in ["Downloads/a.bin", "Downloads/b.bin", "Desktop/c.bin"] {
            let url = home.url.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pattern(2_000_000).write(to: url)
        }
        let log = TrashLog()
        let model = makeModel(home, log: log)
        model.tab = .duplicates
        #expect(model.duplicateRoots == [home.path + "/Downloads", home.path + "/Desktop"])
        model.startDuplicateScan()
        await model.waitForScan(.duplicates)
        let group = try #require(model.duplicateResult?.groups.first)
        #expect(group.files.count == 3)
        #expect(model.selection.isEmpty)

        for file in group.files { model.toggle(file, in: group) }
        #expect(model.selection.count == 2)
        let unticked = try #require(group.files.first { !model.isSelected($0.path) })
        #expect(!model.canSelect(unticked, in: group))

        await model.confirmTrash()
        #expect(log.paths.count == 2)
        #expect(!log.paths.contains(unticked.path))
        #expect(model.duplicateResult?.groups.isEmpty == true)
    }

    @Test func startOverDiscardsResultsAndSelection() async throws {
        let home = try TempDirectory()
        let file = try home.file("Downloads/a.zip", bytes: 10_000)
        let model = makeModel(home)
        model.startMapScan()
        await model.waitForScan(.map)
        let node = try #require(model.mapResult?.root.node(withID: file))
        model.toggle(try #require(model.candidate(for: node)))
        #expect(!model.selection.isEmpty)
        model.startOver(.map)
        #expect(model.mapPhase == .idle)
        #expect(model.mapResult == nil)
        #expect(model.selection.isEmpty)
    }
}
