import CryptoKit
import Darwin
import Foundation
import Quarantine
import RuleKit
import os

public struct DuplicateFile: Sendable, Identifiable, Equatable {
    public let snapshot: FileSnapshot
    public let scanRoot: String
    public let name: String
    /// Allocated bytes.
    public let size: Int64
    public let created: Date
    public let modified: Date
    public let isUserContent: Bool

    public var id: String { snapshot.path }
    public var path: String { snapshot.path }
}

public struct DuplicateGroup: Sendable, Identifiable, Equatable {
    /// Hex SHA-256 of the content.
    public let id: String
    public let logicalSize: Int64
    /// The suggested copy to keep first, then the rest by path.
    public let files: [DuplicateFile]
    /// Path of the copy we'd keep. A label only; nothing is ever selected for the user.
    public let suggestedKeep: String

    /// Bytes freed by trashing every copy but the suggested one (less when the copies are APFS clones).
    public var reclaimable: Int64 {
        files.filter { $0.path != suggestedKeep }.reduce(0) { $0 + $1.size }
    }

    /// The group without the files in `paths`, or nil if fewer than two copies remain.
    public func removing(_ paths: Set<String>) -> DuplicateGroup? {
        let remaining = files.filter { !paths.contains($0.path) }
        guard remaining.count >= 2 else { return nil }
        let keep = remaining.contains { $0.path == suggestedKeep } ? suggestedKeep : remaining[0].path
        return DuplicateGroup(id: id, logicalSize: logicalSize, files: remaining, suggestedKeep: keep)
    }
}

public struct DuplicateOptions: Sendable, Equatable {
    /// Files smaller than this (logical bytes) are ignored.
    public var minimumSize: Int64
    public var maxConcurrentHashes: Int
    public var maxConcurrentWalks: Int

    public init(minimumSize: Int64 = 1_000_000, maxConcurrentHashes: Int = 4, maxConcurrentWalks: Int = 4) {
        self.minimumSize = minimumSize
        self.maxConcurrentHashes = maxConcurrentHashes
        self.maxConcurrentWalks = maxConcurrentWalks
    }
}

public struct DuplicateResult: Sendable, Equatable {
    /// Most reclaimable first.
    public var groups: [DuplicateGroup]
    public var roots: [String]
    public var unreadable: [String]
    public var unreadableCount: Int
    /// Files that could not be read while hashing.
    public var unhashable: Int
    public var isComplete: Bool

    public var reclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }
}

/// Finds byte-identical files: size → first+last 64 KB → full SHA-256. Hard links are one file.
public struct DuplicateFinder: Sendable {
    let policy: TrashPolicy
    let options: DuplicateOptions

    public init(policy: TrashPolicy, options: DuplicateOptions = DuplicateOptions()) {
        self.policy = policy
        self.options = options
    }

    struct Candidate: Sendable {
        let file: DuplicateFile
        let logicalSize: Int64
        let identity: FileIdentity
    }

    public func find(roots: [String], progress: AsyncStream<FinderProgress>.Continuation? = nil) async
        -> DuplicateResult
    {
        let normalized = FileWalker.normalizedRoots(roots)
        let walker = FileWalker(
            policy: policy, includeUserContent: true, measuredPackages: [],
            maxConcurrency: options.maxConcurrentWalks)
        let sink = FinderProgressSink(progress)
        let minimum = options.minimumSize
        let policy = policy
        let outcome = await walker.walk(roots: normalized, progress: sink) { item -> Candidate? in
            guard item.stat.logicalSize >= minimum else { return nil }
            let file = DuplicateFile(
                snapshot: item.stat.snapshot(path: item.path), scanRoot: item.root, name: item.name, size: item.size,
                created: item.stat.birthDate, modified: item.stat.modificationDate,
                isUserContent: policy.isUserContent(item.path))
            return Candidate(
                file: file, logicalSize: item.stat.logicalSize,
                identity: FileIdentity(device: item.stat.device, inode: item.stat.inode))
        }

        // 1. Same size, 2. one entry per inode (hard links are the same file, not duplicates).
        var bySize: [Int64: [Candidate]] = [:]
        for candidate in outcome.items { bySize[candidate.logicalSize, default: []].append(candidate) }
        var sizeGroups: [[Candidate]] = []
        for (_, group) in bySize where group.count > 1 {
            var seen = Set<FileIdentity>()
            let unique = group.sorted { $0.file.path < $1.file.path }.filter { seen.insert($0.identity).inserted }
            if unique.count > 1 { sizeGroups.append(unique) }
        }

        let total = sizeGroups.reduce(0) { $0 + $1.count }
        let counter = HashCounter(total: total, sink: sink)
        sink.comparing(done: 0, total: total)
        var unhashable = 0

        // 3. Partial hash.
        let partialGroups = await regroup(sizeGroups, unhashable: &unhashable) { candidate in
            let digest = FileHasher.partial(candidate.file.path, size: candidate.logicalSize)
            counter.partialDone()
            return digest
        }
        counter.beginFull(partialGroups.reduce(0) { $0 + $1.count })
        // 4. Full hash.
        let fullGroups = await regroupWithDigest(partialGroups, unhashable: &unhashable) { candidate in
            let digest = FileHasher.full(candidate.file.path)
            counter.fullDone()
            return digest
        }

        let groups = fullGroups.map { digest, members in
            makeGroup(id: digest, members: members)
        }
        .sorted { $0.reclaimable != $1.reclaimable ? $0.reclaimable > $1.reclaimable : $0.id < $1.id }
        sink.finish()
        return DuplicateResult(
            groups: groups, roots: normalized, unreadable: outcome.unreadable, unreadableCount: outcome.unreadableCount,
            unhashable: unhashable, isComplete: !Task.isCancelled)
    }

    private func regroup(
        _ groups: [[Candidate]], unhashable: inout Int, digest: @escaping @Sendable (Candidate) -> String?
    ) async -> [[Candidate]] {
        await regroupWithDigest(groups, unhashable: &unhashable, digest: digest).map(\.members)
    }

    /// Splits each group by digest; files that can't be hashed are dropped and counted.
    private func regroupWithDigest(
        _ groups: [[Candidate]], unhashable: inout Int, digest: @escaping @Sendable (Candidate) -> String?
    ) async -> [(digest: String, members: [Candidate])] {
        let flat = groups.flatMap { $0 }
        let digests = await concurrentMap(flat, limit: options.maxConcurrentHashes) { candidate in
            Task.isCancelled ? nil : digest(candidate)
        }
        var result: [(String, [Candidate])] = []
        var index = 0
        for group in groups {
            var byDigest: [String: [Candidate]] = [:]
            var order: [String] = []
            for candidate in group {
                defer { index += 1 }
                guard let value = digests[index] else {
                    unhashable += 1
                    continue
                }
                if byDigest[value] == nil { order.append(value) }
                byDigest[value, default: []].append(candidate)
            }
            for value in order where byDigest[value]!.count > 1 { result.append((value, byDigest[value]!)) }
        }
        return result
    }

    private func makeGroup(id: String, members: [Candidate]) -> DuplicateGroup {
        let files = members.map(\.file)
        let keep = files.min { keepRank($0) < keepRank($1) }!
        let ordered = [keep] + files.filter { $0.path != keep.path }.sorted { $0.path < $1.path }
        return DuplicateGroup(
            id: id, logicalSize: members[0].logicalSize, files: ordered, suggestedKeep: keep.path)
    }

    /// Lower is a better copy to keep: most canonical folder, then oldest, then shortest path.
    func keepRank(_ file: DuplicateFile) -> KeepRank {
        let home = policy.home
        let folders: [(String, Int)] = [
            ("Documents", 0), ("Pictures", 1), ("Movies", 1), ("Music", 1), ("Desktop", 2), ("Downloads", 4),
        ]
        let folder =
            folders.first { pathIsWithin(file.path, home + "/" + $0.0, caseInsensitive: true) }?.1 ?? 3
        return KeepRank(folder: folder, created: file.created, pathLength: file.path.utf8.count, path: file.path)
    }

    struct KeepRank: Comparable {
        let folder: Int
        let created: Date
        let pathLength: Int
        let path: String

        static func < (a: KeepRank, b: KeepRank) -> Bool {
            (a.folder, a.created, a.pathLength, a.path) < (b.folder, b.created, b.pathLength, b.path)
        }
    }
}

/// Reports hashing progress across the partial and full passes as one count.
final class HashCounter: Sendable {
    private let state: OSAllocatedUnfairLock<(done: Int, total: Int)>
    private let sink: FinderProgressSink

    init(total: Int, sink: FinderProgressSink) {
        state = OSAllocatedUnfairLock(initialState: (0, total))
        self.sink = sink
    }

    func partialDone() { advance() }
    func fullDone() { advance() }

    func beginFull(_ count: Int) {
        let value = state.withLock { state in
            state.total += count
            return state
        }
        sink.comparing(done: value.done, total: value.total)
    }

    private func advance() {
        let value = state.withLock { state in
            state.done += 1
            return state
        }
        sink.comparing(done: value.done, total: value.total)
    }
}

/// SHA-256 over file contents, read without following a final symlink.
enum FileHasher {
    static let edge = 64 * 1024
    static let chunk = 1024 * 1024

    /// Digest of the first and last 64 KB (the whole file when it is at most 128 KB).
    static func partial(_ path: String, size: Int64) -> String? {
        withFile(path) { fd in
            var hasher = SHA256()
            if size <= Int64(edge * 2) {
                guard stream(fd, into: &hasher) else { return nil }
            } else {
                guard let head = read(fd, offset: 0, count: edge), head.count == edge,
                    let tail = read(fd, offset: off_t(size) - off_t(edge), count: edge), tail.count == edge
                else { return nil }
                hasher.update(data: head)
                hasher.update(data: tail)
            }
            return hex(hasher.finalize())
        }
    }

    /// Digest of the whole file, streamed in 1 MB chunks. nil on error or cancellation.
    static func full(_ path: String) -> String? {
        withFile(path) { fd in
            var hasher = SHA256()
            guard stream(fd, into: &hasher) else { return nil }
            return hex(hasher.finalize())
        }
    }

    private static func withFile(_ path: String, _ body: (Int32) -> String?) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return body(fd)
    }

    private static func stream(_ fd: Int32, into hasher: inout SHA256) -> Bool {
        var buffer = [UInt8](repeating: 0, count: chunk)
        var offset: off_t = 0
        while true {
            if Task.isCancelled { return false }
            let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, chunk, offset) }
            if count < 0 { return false }
            if count == 0 { return true }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            offset += off_t(count)
        }
    }

    private static func read(_ fd: Int32, offset: off_t, count: Int) -> Data? {
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, offset) }
        guard read >= 0 else { return nil }
        return data.prefix(read)
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
