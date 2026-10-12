import Foundation
import Quarantine
import RuleKit
import ScanEngine
import SpaceKit
import TestSupport
import Testing
import os

@testable import OpenCleanKit

struct CoordinatorSpaceLensTests {
    final class TrashLog: Sendable {
        let moved = OSAllocatedUnfairLock(initialState: [String]())
    }

    func coordinator(_ home: TempDirectory, open: Set<String>? = [], log: TrashLog = TrashLog())
        -> OpenCleanCoordinator
    {
        OpenCleanCoordinator(
            home: home.path, environment: [:], registry: ProbeRegistry([]), processChecker: FakeProcessChecker(),
            openFiles: FakeOpenFiles(open), admin: FakeAdminExecutor(), fullDiskAccess: { .granted },
            trash: { path in
                log.moved.withLock { $0.append(path) }
                return nil
            })
    }

    @Test func scansTheInjectedHomeByDefault() async throws {
        let home = try TempDirectory()
        try home.file("Movies/clip.mov", bytes: 50_000)
        let result = try #require(await coordinator(home).scanSpace())
        #expect(result.rootPath == home.path)
        #expect(result.root.children.contains { $0.name == "Movies" })
    }

    @Test func defaultDuplicateRootsAreExistingUserFolders() throws {
        let home = try TempDirectory()
        try home.directory("Downloads")
        try home.directory("Documents")
        #expect(coordinator(home).defaultDuplicateRoots == [home.path + "/Downloads", home.path + "/Documents"])
    }

    @Test func movesToTheInjectedTrashAfterChecks() async throws {
        let home = try TempDirectory()
        let file = try home.file("Downloads/a.iso", bytes: 200_000)
        let busy = try home.file("Downloads/busy.iso", bytes: 200_000)
        let log = TrashLog()
        let subject = coordinator(home, open: [busy], log: log)
        let found = await subject.findLargeFiles(options: LargeFileOptions(minimumSize: 100_000))
        #expect(found.files.count == 2)
        let requests = found.files.map {
            TrashRequest(
                path: $0.path, scanRoot: $0.scanRoot, device: $0.snapshot.device, inode: $0.snapshot.inode,
                modificationDate: $0.snapshot.modificationDate, isDirectory: $0.snapshot.isDirectory, bytes: $0.size)
        }
        let report = subject.moveToTrash(requests)
        #expect(log.moved.withLock { $0 } == [file])
        #expect(report.notMoved.map(\.outcome) == [.skipped(.inUse)])
    }

    @Test func refusesEverythingWhenOpenFilesAreUnknown() async throws {
        let home = try TempDirectory()
        let file = try home.file("Downloads/a.iso", bytes: 10)
        let stat = try #require(FileStat.of(file))
        let log = TrashLog()
        let report = coordinator(home, open: nil, log: log).moveToTrash([
            TrashRequest(
                path: file, scanRoot: home.path, device: stat.device, inode: stat.inode,
                modificationDate: stat.modificationDate, isDirectory: false, bytes: 10)
        ])
        #expect(log.moved.withLock { $0 }.isEmpty)
        #expect(report.results.map(\.outcome) == [.skipped(.openFilesUnknown)])
    }
}
