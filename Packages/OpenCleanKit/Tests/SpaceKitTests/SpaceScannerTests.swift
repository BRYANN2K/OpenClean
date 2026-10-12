import Foundation
import ScanEngine
import TestSupport
import Testing

@testable import SpaceKit

struct SpaceScannerTests {
    func scan(_ root: String, options: SpaceScanOptions = SpaceScanOptions()) async throws -> SpaceScanResult {
        try #require(await SpaceScanner(options: options).scan(root: root))
    }

    @Test func sizesMatchFileSizerSemantics() async throws {
        let dir = try TempDirectory()
        try dir.file("a/one.bin", bytes: 100_000)
        try dir.file("a/b/two.bin", bytes: 50_000)
        try dir.file("three.bin", bytes: 8_000)
        let result = try await scan(dir.path)
        #expect(result.root.size == FileSizer.allocatedSize(of: dir.path, ledger: HardLinkLedger()))
        #expect(result.root.itemCount == 6)  // root, a, a/b and three files
        #expect(result.isComplete)
        #expect(result.root.children.first?.name == "a")
        let a = try #require(result.root.children.first)
        #expect(a.size == FileSizer.allocatedSize(of: dir.path + "/a", ledger: HardLinkLedger()))
        #expect(a.snapshot?.isDirectory == true)
    }

    @Test func hardLinksAreCountedOnce() async throws {
        let dir = try TempDirectory()
        let original = try dir.file("x/original.bin", bytes: 200_000)
        try FileManager.default.createDirectory(atPath: dir.path + "/y", withIntermediateDirectories: true)
        try FileManager.default.linkItem(atPath: original, toPath: dir.path + "/y/link.bin")
        let result = try await scan(dir.path)
        let fileBytes = try #require(FileManager.default.attributesOfItem(atPath: original)[.size] as? Int)
        let leaves = ["x", "y"].compactMap { name in result.root.children.first { $0.name == name } }
            .flatMap(\.children)
        #expect(leaves.count == 2)
        #expect(leaves.filter { $0.size == 0 }.count == 1)
        #expect(result.root.size < Int64(fileBytes) * 2)
        #expect(result.root.size == FileSizer.allocatedSize(of: dir.path, ledger: HardLinkLedger()))
    }

    @Test func symlinksAreNotFollowed() async throws {
        let dir = try TempDirectory()
        let outside = try TempDirectory()
        try outside.file("huge.bin", bytes: 2_000_000)
        try dir.file("small.bin", bytes: 1_000)
        try dir.symlink("link", to: outside.path)
        let result = try await scan(dir.path)
        let link = try #require(result.root.children.first { $0.name == "link" })
        #expect(link.kind == .symlink)
        #expect(link.children.isEmpty)
        #expect(result.root.size < 1_000_000)
    }

    @Test func unreadableFoldersAreRecorded() async throws {
        let dir = try TempDirectory()
        let locked = try dir.directory("locked")
        try dir.file("locked/secret.bin", bytes: 500_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        let result = try await scan(dir.path)
        #expect(result.unreadable == [locked])
        #expect(result.unreadableCount == 1)
        let node = try #require(result.root.children.first { $0.name == "locked" })
        #expect(node.isUnreadable)
        #expect(node.size < 500_000)
    }

    @Test func foldsExtraChildrenIntoOtherKeepingTotals() async throws {
        let dir = try TempDirectory()
        for index in 0..<5 { try dir.file("f\(index).bin", bytes: (index + 1) * 10_000) }
        let result = try await scan(dir.path, options: SpaceScanOptions(childLimits: [2]))
        let children = result.root.children
        #expect(children.count == 3)
        #expect(children.map(\.name).prefix(2) == ["f4.bin", "f3.bin"])
        let other = try #require(children.last)
        #expect(other.kind == .other(foldedCount: 3))
        #expect(other.snapshot == nil)
        #expect(result.root.size == FileSizer.allocatedSize(of: dir.path, ledger: HardLinkLedger()))
        // Children (including Other) plus the folder's own entry add up to the folder size exactly.
        let own = try #require(FileStatProbe.allocated(dir.path))
        #expect(children.reduce(0) { $0 + $1.size } + own == result.root.size)
    }

    @Test func smallChildrenAreFoldedBelowTheRetentionDepth() async throws {
        let dir = try TempDirectory()
        try dir.file("a/b/tiny.bin", bytes: 1_000)
        try dir.file("a/b/tiny2.bin", bytes: 1_000)
        try dir.file("a/b/big.bin", bytes: 300_000)
        try dir.file("a/c/only-tiny.bin", bytes: 1_000)
        let options = SpaceScanOptions(minRetainedBytes: 100_000, minRetainedDepth: 2)
        let result = try await scan(dir.path, options: options)
        let b = try #require(result.root.node(withID: dir.path + "/a/b"))
        #expect(b.children.map(\.name) == ["big.bin", "Other"])
        #expect(b.children.last?.kind == .other(foldedCount: 2))
        // A single small child is shown as itself rather than as a one-item "Other".
        let c = try #require(result.root.node(withID: dir.path + "/a/c"))
        #expect(c.children.map(\.name) == ["only-tiny.bin"])
    }

    @Test func foldersAtMaxDepthAreSummarized() async throws {
        let dir = try TempDirectory()
        try dir.file("a/b/c/deep.bin", bytes: 100_000)
        let result = try await scan(dir.path, options: SpaceScanOptions(parallelDepth: 1, maxDepth: 2))
        let b = try #require(result.root.node(withID: dir.path + "/a/b"))
        #expect(b.isTruncated)
        #expect(b.children.isEmpty)
        #expect(b.size == FileSizer.allocatedSize(of: dir.path + "/a/b", ledger: HardLinkLedger()))
    }

    @Test func removingNodesSubtractsUpTheTree() async throws {
        let dir = try TempDirectory()
        let file = try dir.file("a/b/big.bin", bytes: 300_000)
        try dir.file("a/keep.bin", bytes: 10_000)
        let result = try await scan(dir.path)
        let big = try #require(result.root.node(withID: file))
        let updated = result.root.removing([file])
        #expect(updated.size == result.root.size - big.size)
        #expect(updated.itemCount == result.root.itemCount - 1)
        #expect(updated.node(withID: file) == nil)
        let a = try #require(updated.node(withID: dir.path + "/a"))
        #expect(a.size == (result.root.node(withID: dir.path + "/a")?.size ?? 0) - big.size)
        #expect(updated.trail(to: dir.path + "/a/b")?.map(\.name) == [result.root.name, "a", "b"])
    }

    @Test func cancelledScanIsMarkedIncomplete() async throws {
        let dir = try TempDirectory()
        try dir.file("a/one.bin", bytes: 1_000)
        let path = dir.path
        let task = Task { () -> SpaceScanResult? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await SpaceScanner().scan(root: path)
        }
        let result = try #require(await task.value)
        #expect(!result.isComplete)
    }

    @Test func streamsProgress() async throws {
        let dir = try TempDirectory()
        for index in 0..<20 { try dir.file("d\(index % 3)/f\(index).bin", bytes: 1_000) }
        let (stream, continuation) = AsyncStream<SpaceScanProgress>.makeStream()
        _ = await SpaceScanner(options: SpaceScanOptions(progressInterval: 5)).scan(
            root: dir.path, progress: continuation)
        continuation.finish()
        var updates: [SpaceScanProgress] = []
        for await update in stream { updates.append(update) }
        #expect(updates.count > 1)
        #expect(updates.last?.items == 24)
        #expect((updates.last?.bytes ?? 0) > 0)
    }

    @Test func missingRootReturnsNil() async throws {
        let dir = try TempDirectory()
        #expect(await SpaceScanner().scan(root: dir.path + "/nope") == nil)
        let file = try dir.file("plain.bin", bytes: 10)
        #expect(await SpaceScanner().scan(root: file) == nil)
    }
}
