import Foundation
import Quarantine
import RuleKit
import TestSupport
import Testing

@testable import SpaceKit

enum FileStatProbe {
    static func allocated(_ path: String) -> Int64? { FileStat.of(path)?.allocatedBytes }
}

struct LargeFileFinderTests {
    func find(
        _ home: TempDirectory, includeUserContent: Bool = false, roots: [String]? = nil
    ) async -> LargeFileResult {
        let options = LargeFileOptions(minimumSize: 100_000, includeUserContent: includeUserContent)
        return await LargeFileFinder(policy: TrashPolicy(home: home.path), options: options)
            .find(roots: roots ?? [home.path])
    }

    @Test func findsLargeFilesLargestFirstAndSkipsSmallOnes() async throws {
        let home = try TempDirectory()
        try home.file("Downloads/installer.dmg", bytes: 400_000)
        try home.file("Movies/clip.mov", bytes: 600_000)
        try home.file("Downloads/notes.txt", bytes: 2_000)
        let result = await find(home)
        #expect(result.files.map(\.name) == ["clip.mov", "installer.dmg"])
        #expect(result.files.map(\.kind) == [.video, .installer])
        #expect(result.files.allSatisfy { !$0.isUserContent })
        #expect(result.isComplete)
    }

    @Test func skipsLibraryBundlesTrashAndProtectedFolders() async throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/big.zip", bytes: 300_000)
        try home.file("Downloads/Tool.app/Contents/Resources/big.bin", bytes: 300_000)
        try home.file(".Trash/old.iso", bytes: 300_000)
        try home.file(".ssh/huge.key", bytes: 300_000)
        try home.file("Pictures/Photos Library.photoslibrary/originals/a.mov", bytes: 300_000)
        try home.file("Downloads/kept.zip", bytes: 300_000)
        let result = await find(home)
        #expect(result.files.map(\.name) == ["kept.zip"])
    }

    @Test func documentsAndDesktopOnlyWhenOptedIn() async throws {
        let home = try TempDirectory()
        try home.file("Documents/archive.zip", bytes: 300_000)
        try home.file("Desktop/movie.mp4", bytes: 200_000)
        #expect(await find(home).files.isEmpty)
        let included = await find(home, includeUserContent: true)
        #expect(included.files.map(\.name) == ["archive.zip", "movie.mp4"])
        #expect(included.files.allSatisfy { $0.isUserContent })
    }

    @Test func measuresVirtualMachinePackagesAsOneItem() async throws {
        let home = try TempDirectory()
        try home.file("VMs/Linux.utm/Data/disk.qcow2", bytes: 300_000)
        try home.file("VMs/Linux.utm/config.plist", bytes: 100)
        let result = await find(home)
        #expect(result.files.map(\.name) == ["Linux.utm"])
        #expect(result.files.first?.kind == .diskImage)
        #expect(result.files.first?.snapshot.isDirectory == true)
    }

    @Test func listsHardLinkedFilesOnce() async throws {
        let home = try TempDirectory()
        let original = try home.file("Downloads/a.iso", bytes: 300_000)
        try FileManager.default.linkItem(atPath: original, toPath: home.path + "/Downloads/b.iso")
        #expect(await find(home).files.count == 1)
    }

    @Test func filtersBySizeAndAge() async throws {
        let home = try TempDirectory()
        let old = try home.file("Downloads/old.zip", bytes: 300_000)
        try home.file("Downloads/recent.zip", bytes: 500_000)
        let longAgo = Date(timeIntervalSinceNow: -400 * 86_400)
        var values = URLResourceValues()
        values.contentAccessDate = longAgo
        values.contentModificationDate = longAgo
        var url = URL(fileURLWithPath: old)
        try url.setResourceValues(values)

        let files = await find(home).files
        #expect(LargeFileFilter(minimumSize: 100_000).apply(files).count == 2)
        #expect(LargeFileFilter(minimumSize: 400_000).apply(files).map(\.name) == ["recent.zip"])
        #expect(LargeFileFilter(minimumSize: 100_000, notOpenedForDays: 365).apply(files).map(\.name) == ["old.zip"])
        let oldFile = try #require(files.first { $0.name == "old.zip" })
        #expect(abs((oldFile.lastOpened ?? .now).timeIntervalSince(longAgo)) < 2)
    }

    @Test func groupsByKindInFixedOrder() {
        func file(_ name: String, _ size: Int64) -> LargeFile {
            LargeFile(
                snapshot: FileSnapshot(
                    path: "/x/" + name, device: 1, inode: 1, modificationDate: .now, isDirectory: false),
                scanRoot: "/x", name: name, size: size, kind: FileKind(fileName: name), lastOpened: nil,
                modified: .now, isUserContent: false)
        }
        let groups = LargeFileFilter.grouped([file("a.pkg", 3), file("b.MKV", 2), file("c.bin", 1), file("d.tgz", 1)])
        #expect(groups.map(\.kind) == [.video, .archive, .installer, .other])
    }

    @Test func mapsExtensionsToKinds() {
        #expect(FileKind(fileName: "Movie.MOV") == .video)
        #expect(FileKind(fileName: "backup.tar.gz") == .archive)
        #expect(FileKind(fileName: "ubuntu.iso") == .diskImage)
        #expect(FileKind(fileName: "Xcode.xip") == .installer)
        #expect(FileKind(fileName: "Setup.dmg") == .installer)
        #expect(FileKind(fileName: "data.sqlite") == .other)
        #expect(FileKind(fileName: "README") == .other)
    }
}

struct DuplicateFinderTests {
    func find(_ home: TempDirectory, roots: [String]? = nil, minimumSize: Int64 = 1) async -> DuplicateResult {
        await DuplicateFinder(policy: TrashPolicy(home: home.path), options: DuplicateOptions(minimumSize: minimumSize))
            .find(roots: roots ?? [home.path])
    }

    func write(_ home: TempDirectory, _ relative: String, _ data: Data) throws -> String {
        let url = home.url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url.path
    }

    func pattern(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) &+ seed })
    }

    @Test func sameContentWithDifferentNamesIsADuplicate() async throws {
        let home = try TempDirectory()
        let a = try write(home, "Downloads/photo.jpg", pattern(300_000, seed: 1))
        let b = try write(home, "Pictures/holiday copy.jpg", pattern(300_000, seed: 1))
        let result = await find(home)
        #expect(result.groups.count == 1)
        let group = try #require(result.groups.first)
        #expect(Set(group.files.map(\.path)) == [a, b])
        #expect(group.logicalSize == 300_000)
        #expect(group.reclaimable > 0)
        #expect(result.reclaimable == group.reclaimable)
        #expect(result.isComplete)
    }

    @Test func sameSizeDifferentContentIsNotADuplicate() async throws {
        let home = try TempDirectory()
        try write(home, "Downloads/a.bin", pattern(50_000, seed: 1))
        try write(home, "Downloads/b.bin", pattern(50_000, seed: 2))
        #expect(await find(home).groups.isEmpty)
    }

    @Test func filesDifferingOnlyInTheMiddleAreNotDuplicates() async throws {
        let home = try TempDirectory()
        var first = pattern(400_000, seed: 7)
        let second = first
        first[200_000] ^= 0xFF
        try write(home, "Downloads/a.bin", first)
        try write(home, "Downloads/b.bin", second)
        #expect(await find(home).groups.isEmpty)
    }

    @Test func hardLinksAreNotDuplicates() async throws {
        let home = try TempDirectory()
        let original = try write(home, "Downloads/a.bin", pattern(80_000, seed: 3))
        try FileManager.default.linkItem(atPath: original, toPath: home.path + "/Downloads/b.bin")
        #expect(await find(home).groups.isEmpty)
    }

    @Test func smallFilesAreIgnoredByDefault() async throws {
        let home = try TempDirectory()
        try write(home, "Downloads/a.txt", pattern(1_000, seed: 4))
        try write(home, "Downloads/b.txt", pattern(1_000, seed: 4))
        #expect(await find(home, minimumSize: DuplicateOptions().minimumSize).groups.isEmpty)
        #expect(await find(home).groups.count == 1)
    }

    @Test func suggestsTheCopyInTheMostCanonicalFolder() async throws {
        let home = try TempDirectory()
        let download = try write(home, "Downloads/report.pdf", pattern(20_000, seed: 5))
        let document = try write(home, "Documents/Reports/report.pdf", pattern(20_000, seed: 5))
        let result = await find(home)
        let group = try #require(result.groups.first)
        #expect(group.suggestedKeep == document)
        #expect(group.files.first?.path == document)
        #expect(group.files.first { $0.path == document }?.isUserContent == true)
        #expect(group.files.first { $0.path == download }?.isUserContent == false)
        #expect(group.reclaimable == FileStatProbe.allocated(download))
    }

    @Test func overlappingRootsDoNotDoubleCount() async throws {
        let home = try TempDirectory()
        try write(home, "Downloads/a.bin", pattern(10_000, seed: 6))
        try write(home, "Downloads/sub/b.bin", pattern(10_000, seed: 6))
        let result = await find(home, roots: [home.path + "/Downloads", home.path + "/Downloads/sub"])
        #expect(result.groups.first?.files.count == 2)
        #expect(result.roots == [home.path + "/Downloads"])
    }

    @Test func skipsPackagesAndLibrary() async throws {
        let home = try TempDirectory()
        try write(home, "Downloads/a.bin", pattern(10_000, seed: 8))
        try write(home, "Library/Caches/a.bin", pattern(10_000, seed: 8))
        try write(home, "Music/Music Library.musiclibrary/a.bin", pattern(10_000, seed: 8))
        #expect(await find(home).groups.isEmpty)
    }

    @Test func removingFilesShrinksOrDropsGroups() async throws {
        let home = try TempDirectory()
        let a = try write(home, "Downloads/a.bin", pattern(10_000, seed: 9))
        let b = try write(home, "Downloads/b.bin", pattern(10_000, seed: 9))
        let c = try write(home, "Downloads/c.bin", pattern(10_000, seed: 9))
        let group = try #require(await find(home).groups.first)
        #expect(group.files.count == 3)
        #expect(group.removing([c])?.files.count == 2)
        #expect(group.removing([b, c]) == nil)
        let withoutKeep = try #require(group.removing([group.suggestedKeep]))
        #expect(withoutKeep.suggestedKeep != group.suggestedKeep)
        #expect(Set([a, b, c]).contains(withoutKeep.suggestedKeep))
    }
}
