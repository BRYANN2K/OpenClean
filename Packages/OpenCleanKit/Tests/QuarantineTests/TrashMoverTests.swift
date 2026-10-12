import Foundation
import RuleKit
import TestSupport
import Testing
import os

@testable import Quarantine

/// Records what would have been moved to the Trash. Never touches the real Trash.
final class FakeTrash: Sendable {
    private let moved = OSAllocatedUnfairLock(initialState: [String]())
    let failing: Bool

    init(failing: Bool = false) {
        self.failing = failing
    }

    var paths: [String] { moved.withLock { $0 } }

    var operation: TrashOperation {
        { path in
            struct Refused: Error {}
            if self.failing { throw Refused() }
            self.moved.withLock { $0.append(path) }
            return "/fake/.Trash/" + (path as NSString).lastPathComponent
        }
    }
}

struct TrashPolicyTests {
    let home = "/Users/tester"
    var policy: TrashPolicy { TrashPolicy(home: home) }

    @Test(arguments: [
        "/System/Library/CoreServices/Finder.app",
        "/System",
        "/usr/local/bin/tool",
        "/bin/ls",
        "/Library/Preferences/x.plist",
        "/Applications/Safari.app",
        "/Applications/Utilities",
        "/private/etc/hosts",
        "/private/var/db/receipts",
        "/",
        "/Users",
        "/Volumes",
        "/Users/tester",
        "/Users/tester/Library",
        "/Users/tester/Library/Caches/com.example",
        "/Users/tester/library/caches/com.example",
        "/Users/tester/Library/Keychains/login.keychain-db",
        "/Users/tester/Library/Application Support/OpenClean/Quarantine",
        "/Users/tester/Library/Mail/V10",
        "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/a.txt",
        "/Users/tester/.ssh/id_ed25519",
        "/Users/tester/.gnupg/pubring.kbx",
        "/Users/tester/Applications/Tool.app",
        "/Users/tester/Downloads/Tool.app",
        "/Users/tester/Downloads/Tool.APP/Contents/MacOS/Tool",
        "/Users/tester/Documents/Tool.app",
        "/Users/tester/Pictures/Photos Library.photoslibrary",
        "/Users/tester/Pictures/Photos Library.photoslibrary/database/Photos.sqlite",
        "/Users/tester/Movies/VM.utm/Data/disk.img",
        "/Users/tester/.Trash/old.zip",
        "/Users/tester/Documents",
        "/Users/tester/Desktop",
        "/Users/tester/Downloads/../Library/x",
        "Users/tester/Downloads/a.zip",
    ])
    func refusesCriticalPaths(_ path: String) {
        #expect(policy.verdict(for: path, isDirectory: false).refusal != nil, "\(path) must be refused")
        #expect(policy.verdict(for: path, isDirectory: true).refusal != nil, "\(path) must be refused")
    }

    @Test func allowsOrdinaryUserFiles() {
        #expect(policy.verdict(for: home + "/Downloads/big.dmg", isDirectory: false) == .allowed)
        #expect(policy.verdict(for: home + "/Movies/Old Project", isDirectory: true) == .allowed)
        #expect(policy.verdict(for: home + "/Movies/VM.utm", isDirectory: true) == .allowed)
        #expect(policy.verdict(for: "/private/var/folders/xy/T/scratch.bin", isDirectory: false) == .allowed)
        #expect(policy.verdict(for: "/Volumes/External/backup.zip", isDirectory: false) == .allowed)
    }

    @Test func documentsAndDesktopAllowOnlySingleFiles() {
        #expect(policy.verdict(for: home + "/Documents/report.pdf", isDirectory: false) == .allowedUserContent)
        #expect(policy.verdict(for: home + "/Desktop/a/b/movie.mov", isDirectory: false) == .allowedUserContent)
        #expect(policy.verdict(for: home + "/DOCUMENTS/report.pdf", isDirectory: false) == .allowedUserContent)
        #expect(policy.verdict(for: home + "/Documents/Projects", isDirectory: true).refusal != nil)
        #expect(policy.isUserContent(home + "/Desktop/x"))
        #expect(!policy.isUserContent(home + "/Desktop"))
        #expect(!policy.isUserContent(home + "/Downloads/x"))
    }

    @Test func subtreeVerdictGuidesWalkers() {
        #expect(policy.subtreeVerdict(of: home) == .allowed)
        #expect(policy.subtreeVerdict(of: home + "/Documents") == .allowedUserContent)
        #expect(policy.subtreeVerdict(of: home + "/Library").refusal != nil)
        #expect(policy.subtreeVerdict(of: home + "/Downloads/Tool.app").refusal != nil)
        #expect(policy.subtreeVerdict(of: home + "/Music/Music Library.musiclibrary").refusal != nil)
        #expect(policy.subtreeVerdict(of: home + "/.ssh").refusal != nil)
    }
}

struct TrashMoverTests {
    func request(_ path: String, root: String) throws -> TrashRequest {
        let stat = try #require(FileStat.of(path))
        return TrashRequest(
            path: path, scanRoot: root, device: stat.device, inode: stat.inode,
            modificationDate: stat.modificationDate, isDirectory: stat.isDirectory, bytes: stat.allocatedBytes)
    }

    func mover(_ home: TempDirectory, open: Set<String>? = [], trash: FakeTrash) -> TrashMover {
        TrashMover(policy: TrashPolicy(home: home.path), openPaths: open, trash: trash.operation)
    }

    @Test func movesUnchangedFileThroughInjectedTrash() throws {
        let home = try TempDirectory()
        let file = try home.file("Downloads/big.dmg", bytes: 4_096)
        let trash = FakeTrash()
        let report = mover(home, trash: trash).move([try request(file, root: home.path)])
        #expect(trash.paths == [file])
        #expect(report.trashed.map(\.path) == [file])
        #expect(report.trashedBytes > 0)
        #expect(report.notMoved.isEmpty)
    }

    @Test func refusesCriticalPathsWithoutCallingTrash() throws {
        let home = try TempDirectory()
        let paths = [
            try home.file("Library/Caches/blob", bytes: 10),
            try home.file("Library/Keychains/login.keychain-db", bytes: 10),
            try home.file(".ssh/id_rsa", bytes: 10),
            try home.file("Library/Application Support/OpenClean/settings.json", bytes: 10),
            try home.file("Downloads/Tool.app/Contents/Info.plist", bytes: 10),
            try home.directory("Downloads/Tool.app"),
            try home.file("Pictures/Photos Library.photoslibrary/db", bytes: 10),
            try home.directory("Documents/Projects"),
            try home.directory("Documents"),
            try home.file(".Trash/old.zip", bytes: 10),
        ]
        let trash = FakeTrash()
        let report = mover(home, trash: trash).move(try paths.map { try request($0, root: home.path) })
        #expect(trash.paths.isEmpty)
        for result in report.results {
            guard case .skipped(.protected) = result.outcome else {
                Issue.record("\(result.request.path) was not refused: \(result.outcome)")
                continue
            }
        }
    }

    @Test func movesSingleFileFromDocumentsAsUserContent() throws {
        let home = try TempDirectory()
        let file = try home.file("Documents/copy of report.pdf", bytes: 100)
        let trash = FakeTrash()
        let report = mover(home, trash: trash).move([try request(file, root: home.path)])
        #expect(trash.paths == [file])
        #expect(report.trashed.count == 1)
    }

    @Test func skipsChangedReplacedAndMissingItems() throws {
        let home = try TempDirectory()
        let changed = try home.file("Downloads/changed.zip", bytes: 100)
        let replaced = try home.file("Downloads/replaced.zip", bytes: 100)
        let missing = try home.file("Downloads/missing.zip", bytes: 100)
        let requests = try [changed, replaced, missing].map { try request($0, root: home.path) }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -5_000)], ofItemAtPath: changed)
        try FileManager.default.removeItem(atPath: replaced)
        try home.file("Downloads/replaced.zip", bytes: 100, modified: requests[1].modificationDate)
        try FileManager.default.removeItem(atPath: missing)

        let trash = FakeTrash()
        let report = mover(home, trash: trash).move(requests)
        #expect(trash.paths.isEmpty)
        #expect(
            report.results.map(\.outcome) == [
                .skipped(.changedSinceScan), .skipped(.changedSinceScan), .skipped(.missing),
            ])
    }

    @Test func skipsItemsOutsideTheScanRootAndTheRootItself() throws {
        let home = try TempDirectory()
        let file = try home.file("Downloads/a.zip", bytes: 100)
        let movies = try home.directory("Movies")
        let trash = FakeTrash()
        let report = mover(home, trash: trash).move([
            try request(file, root: movies), try request(movies, root: movies),
        ])
        #expect(trash.paths.isEmpty)
        #expect(report.results.map(\.outcome) == [.skipped(.outsideScanRoot), .skipped(.outsideScanRoot)])
    }

    @Test func skipsOpenFilesAndFoldersContainingThem() throws {
        let home = try TempDirectory()
        let file = try home.file("Downloads/open.mov", bytes: 100)
        let folder = try home.directory("Movies/Project")
        try home.file("Movies/Project/render.mov", bytes: 100)
        let trash = FakeTrash()
        let report = mover(home, open: [file, folder + "/render.mov"], trash: trash)
            .move([try request(file, root: home.path), try request(folder, root: home.path)])
        #expect(trash.paths.isEmpty)
        #expect(report.results.map(\.outcome) == [.skipped(.inUse), .skipped(.inUse)])
    }

    @Test func skipsEverythingWhenOpenFilesAreUnknown() throws {
        let home = try TempDirectory()
        let file = try home.file("Downloads/a.zip", bytes: 100)
        let trash = FakeTrash()
        let report = mover(home, open: nil, trash: trash).move([try request(file, root: home.path)])
        #expect(trash.paths.isEmpty)
        #expect(report.results.map(\.outcome) == [.skipped(.openFilesUnknown)])
    }

    @Test func skipsWhenAParentWasSwappedForASymlink() throws {
        let home = try TempDirectory()
        let file = try home.file("Downloads/set/a.zip", bytes: 100)
        let scanned = try request(file, root: home.path)
        try FileManager.default.moveItem(atPath: home.path + "/Downloads/set", toPath: home.path + "/Elsewhere")
        try home.symlink("Downloads/set", to: home.path + "/Elsewhere")
        let trash = FakeTrash()
        let report = mover(home, trash: trash).move([scanned])
        #expect(trash.paths.isEmpty)
        #expect(report.results.map(\.outcome) == [.skipped(.pathChanged)])
    }

    @Test func skipsItemsInsideAnotherSelectedFolder() throws {
        let home = try TempDirectory()
        let folder = try home.directory("Movies/Old")
        let inner = try home.file("Movies/Old/clip.mov", bytes: 100)
        let trash = FakeTrash()
        let report = mover(home, trash: trash).move([
            try request(inner, root: home.path), try request(folder, root: home.path),
        ])
        #expect(trash.paths == [folder])
        #expect(report.results.first?.outcome == .skipped(.coveredBySelection))
    }

    @Test func recordsTrashFailures() throws {
        let home = try TempDirectory()
        let file = try home.file("Downloads/a.zip", bytes: 100)
        let report = mover(home, trash: FakeTrash(failing: true)).move([try request(file, root: home.path)])
        guard case .failed = report.results.first?.outcome else {
            Issue.record("expected a failure, got \(String(describing: report.results.first?.outcome))")
            return
        }
        #expect(report.trashed.isEmpty)
    }

    /// Space Lens lists symlinks (also dangling ones); trashing one moves the link, never its target.
    @Test func trashesSymlinksAsLinksNeverTheirTargets() throws {
        let home = try TempDirectory()
        let target = try home.file("Elsewhere/real.bin", bytes: 100)
        let link = try home.symlink("Downloads/link.bin", to: target)
        let dangling = try home.symlink("Downloads/dangling", to: home.path + "/nothing-here")
        let moved = try home.directory("FakeTrash")
        let operation: TrashOperation = { path in
            let destination = moved + "/" + (path as NSString).lastPathComponent
            try FileManager.default.moveItem(atPath: path, toPath: destination)
            return destination
        }
        let subject = TrashMover(policy: TrashPolicy(home: home.path), openPaths: [], trash: operation)
        let report = subject.move([try request(link, root: home.path), try request(dangling, root: home.path)])
        #expect(report.trashed.map(\.path) == [link, dangling])
        #expect(FileStat.of(link) == nil && FileStat.of(dangling) == nil)
        #expect(FileStat.of(moved + "/link.bin")?.isSymlink == true)
        #expect(FileStat.of(moved + "/dangling")?.isSymlink == true)
        #expect(FileStat.of(target)?.isSymlink == false)
        #expect(try Data(contentsOf: URL(fileURLWithPath: target)).count == 100)
    }

    @Test func aSymlinkSwappedForAnotherSinceTheScanIsSkipped() throws {
        let home = try TempDirectory()
        let link = try home.symlink("Downloads/link", to: home.path + "/a")
        let scanned = try request(link, root: home.path)
        try FileManager.default.removeItem(atPath: link)
        try home.symlink("Downloads/link", to: home.path + "/b")
        let trash = FakeTrash()
        let report = mover(home, trash: trash).move([scanned])
        #expect(trash.paths.isEmpty)
        #expect(report.results.map(\.outcome) == [.skipped(.changedSinceScan)])

        // The last component is not resolved, so ".." must still be refused.
        _ = try home.directory("Downloads/sub")
        let dotDot = try request(home.path + "/Downloads/sub/..", root: home.path)
        #expect(mover(home, trash: trash).check(dotDot) != nil)
    }
}
