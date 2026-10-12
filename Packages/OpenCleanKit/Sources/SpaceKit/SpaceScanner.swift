import Foundation
import ScanEngine
import os

public struct SpaceScanOptions: Sendable, Equatable {
    /// Subtrees walked at the same time.
    public var maxConcurrency: Int
    /// Folders shallower than this are listed inline and fan out into child tasks.
    public var parallelDepth: Int
    /// Folders at this depth or deeper keep no children (summarized leaves).
    public var maxDepth: Int
    /// Children kept per folder, indexed by the folder's depth; the last value applies deeper.
    public var childLimits: [Int]
    /// From `minRetainedDepth` down, children smaller than this are folded into "Other".
    public var minRetainedBytes: Int64
    public var minRetainedDepth: Int
    /// Unreadable folder paths recorded (all are counted).
    public var unreadableLimit: Int
    /// Entries between progress updates.
    public var progressInterval: Int

    public init(
        maxConcurrency: Int = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount)),
        parallelDepth: Int = 2, maxDepth: Int = 7, childLimits: [Int] = [50, 50, 20, 20, 10],
        minRetainedBytes: Int64 = 4 * 1024 * 1024, minRetainedDepth: Int = 2, unreadableLimit: Int = 200,
        progressInterval: Int = 1_000
    ) {
        self.maxConcurrency = maxConcurrency
        self.parallelDepth = parallelDepth
        self.maxDepth = maxDepth
        self.childLimits = childLimits
        self.minRetainedBytes = minRetainedBytes
        self.minRetainedDepth = minRetainedDepth
        self.unreadableLimit = unreadableLimit
        self.progressInterval = progressInterval
    }

    func childLimit(atDepth depth: Int) -> Int {
        guard let last = childLimits.last else { return 0 }
        return depth < childLimits.count ? childLimits[depth] : last
    }
}

public struct SpaceScanProgress: Sendable, Equatable {
    public var items: Int
    public var bytes: Int64
    public var unreadable: Int

    public init(items: Int = 0, bytes: Int64 = 0, unreadable: Int = 0) {
        self.items = items
        self.bytes = bytes
        self.unreadable = unreadable
    }
}

public struct SpaceScanResult: Sendable, Equatable {
    public var root: SpaceNode
    /// Canonical root path that was scanned.
    public var rootPath: String
    /// First `unreadableLimit` folders that could not be listed.
    public var unreadable: [String]
    public var unreadableCount: Int
    /// Mount points inside the root that were not entered.
    public var otherVolumes: [String]
    public var isComplete: Bool
}

/// Builds a bounded size tree of a folder. Reads only; never follows symlinks or crosses volumes.
public struct SpaceScanner: Sendable {
    public let options: SpaceScanOptions

    public init(options: SpaceScanOptions = SpaceScanOptions()) {
        self.options = options
    }

    /// nil when `root` doesn't exist or isn't a folder. `root` should be canonical (realpath'd).
    public func scan(root: String, progress: AsyncStream<SpaceScanProgress>.Continuation? = nil) async
        -> SpaceScanResult?
    {
        guard let stat = EntryStat.of(root), stat.isDirectory else { return nil }
        let context = SpaceScanContext(options: options, rootDevice: stat.device, progress: progress)
        let name = root == "/" ? "/" : (root as NSString).lastPathComponent
        let node = await scanParallel(path: root, name: name, stat: stat, depth: 0, context: context)
        let summary = context.finish()
        return SpaceScanResult(
            root: node, rootPath: root, unreadable: summary.unreadable, unreadableCount: summary.unreadableCount,
            otherVolumes: summary.otherVolumes, isComplete: !Task.isCancelled)
    }

    // MARK: Walking

    private func scanParallel(path: String, name: String, stat: EntryStat, depth: Int, context: SpaceScanContext) async
        -> SpaceNode
    {
        guard depth < options.parallelDepth, depth < options.maxDepth else {
            await context.gate.acquire()
            let node = walk(path: path, name: name, stat: stat, depth: depth, retain: true, context: context)
            await context.gate.release()
            return node
        }
        guard !Task.isCancelled, let entries = DirectoryReader.entries(of: path) else {
            return unreadableOrCancelled(path: path, name: name, stat: stat, context: context)
        }
        var local = Tally()
        local.add(stat, context.ledger)
        var leaves: [SpaceNode] = []
        var folders: [(path: String, name: String, stat: EntryStat)] = []
        for entry in entries {
            let childPath = joinPath(path, entry.name)
            if entry.stat.isDirectory {
                if entry.stat.device != context.rootDevice {
                    context.recordOtherVolume(childPath)
                    continue
                }
                folders.append((childPath, entry.name, entry.stat))
            } else {
                leaves.append(
                    leaf(path: childPath, name: entry.name, stat: entry.stat, tally: &local, context: context))
            }
        }
        context.flush(&local)
        let subfolders = await withTaskGroup(of: SpaceNode.self) { group in
            for folder in folders {
                group.addTask {
                    await scanParallel(
                        path: folder.path, name: folder.name, stat: folder.stat, depth: depth + 1, context: context)
                }
            }
            var nodes: [SpaceNode] = []
            for await node in group { nodes.append(node) }
            return nodes
        }
        return assemble(
            path: path, name: name, stat: stat, depth: depth, children: leaves + subfolders,
            ownBytes: stat.allocatedBytes)
    }

    /// Synchronous depth-first walk of one subtree. With `retain == false` only totals are kept.
    private func walk(path: String, name: String, stat: EntryStat, depth: Int, retain: Bool, context: SpaceScanContext)
        -> SpaceNode
    {
        guard !Task.isCancelled, let entries = DirectoryReader.entries(of: path) else {
            return unreadableOrCancelled(path: path, name: name, stat: stat, context: context)
        }
        var local = Tally()
        local.add(stat, context.ledger)
        let keep = retain && depth < options.maxDepth
        var children: [SpaceNode] = []
        var size = stat.allocatedBytes
        var count = 1
        for entry in entries {
            let childPath = joinPath(path, entry.name)
            let child: SpaceNode
            if entry.stat.isDirectory {
                if entry.stat.device != context.rootDevice {
                    context.recordOtherVolume(childPath)
                    continue
                }
                context.flush(&local)
                child = walk(
                    path: childPath, name: entry.name, stat: entry.stat, depth: depth + 1, retain: keep,
                    context: context)
            } else {
                child = leaf(path: childPath, name: entry.name, stat: entry.stat, tally: &local, context: context)
            }
            if keep {
                children.append(child)
            } else {
                size += child.size
                count += child.itemCount
            }
        }
        context.flush(&local)
        if keep {
            return assemble(
                path: path, name: name, stat: stat, depth: depth, children: children,
                ownBytes: stat.allocatedBytes)
        }
        return SpaceNode(
            id: path, name: name, kind: .directory, size: size, itemCount: count, isTruncated: !entries.isEmpty,
            snapshot: stat.snapshot(path: path))
    }

    private func leaf(path: String, name: String, stat: EntryStat, tally: inout Tally, context: SpaceScanContext)
        -> SpaceNode
    {
        let bytes = tally.add(stat, context.ledger)
        return SpaceNode(
            id: path, name: name, kind: stat.isSymlink ? .symlink : .file, size: bytes, itemCount: 1,
            snapshot: stat.snapshot(path: path))
    }

    private func unreadableOrCancelled(path: String, name: String, stat: EntryStat, context: SpaceScanContext)
        -> SpaceNode
    {
        var local = Tally()
        let bytes = local.add(stat, context.ledger)
        let unreadable = !Task.isCancelled
        if unreadable { context.recordUnreadable(path) }
        context.flush(&local)
        return SpaceNode(
            id: path, name: name, kind: .directory, size: bytes, itemCount: 1, isUnreadable: unreadable,
            snapshot: stat.snapshot(path: path))
    }

    /// Sums children, keeps the largest within the limits and folds the rest into one aggregate.
    private func assemble(
        path: String, name: String, stat: EntryStat, depth: Int, children: [SpaceNode], ownBytes: Int64
    ) -> SpaceNode {
        let sorted = children.sorted(by: SpaceNode.largestFirst)
        let limit = options.childLimit(atDepth: depth)
        let minimum = depth >= options.minRetainedDepth ? options.minRetainedBytes : 0
        var kept: [SpaceNode] = []
        var foldedSize: Int64 = 0
        var foldedItems = 0
        var foldedCount = 0
        var lastFolded: SpaceNode?
        var total = ownBytes
        var items = 1
        for child in sorted {
            total += child.size
            items += child.itemCount
            if kept.count < limit && child.size >= minimum {
                kept.append(child)
            } else {
                foldedSize += child.size
                foldedItems += child.itemCount
                foldedCount += 1
                lastFolded = child
            }
        }
        if foldedCount == 1, let lastFolded {
            // An "Other" holding a single item saves nothing; show the item itself.
            kept.append(lastFolded)
        } else if foldedCount > 1 {
            kept.append(
                SpaceNode(
                    id: path + "\u{0}other", name: "Other", kind: .other(foldedCount: foldedCount), size: foldedSize,
                    itemCount: foldedItems, snapshot: nil))
        }
        return SpaceNode(
            id: path, name: name, kind: .directory, size: total, itemCount: items, children: kept,
            snapshot: stat.snapshot(path: path))
    }
}

/// Per-directory counters, flushed into the shared context to keep lock traffic low.
struct Tally {
    var items = 0
    var bytes: Int64 = 0

    /// Counts an entry and returns the bytes it contributes (0 for an already-seen hard link).
    @discardableResult
    mutating func add(_ stat: EntryStat, _ ledger: HardLinkLedger) -> Int64 {
        items += 1
        var counted = stat.allocatedBytes
        if !stat.isDirectory, stat.linkCount > 1, !ledger.claim(device: stat.device, inode: UInt64(stat.inode)) {
            counted = 0
        }
        bytes += counted
        return counted
    }
}

/// Shared, thread-safe state of one scan.
final class SpaceScanContext: Sendable {
    struct State {
        var progress = SpaceScanProgress()
        var lastReported = 0
        var unreadable: [String] = []
        var otherVolumes: [String] = []
    }

    let options: SpaceScanOptions
    let rootDevice: Int32
    let ledger = HardLinkLedger()
    let gate: ConcurrencyGate
    let continuation: AsyncStream<SpaceScanProgress>.Continuation?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(options: SpaceScanOptions, rootDevice: Int32, progress: AsyncStream<SpaceScanProgress>.Continuation?) {
        self.options = options
        self.rootDevice = rootDevice
        gate = ConcurrencyGate(limit: options.maxConcurrency)
        continuation = progress
    }

    func flush(_ tally: inout Tally) {
        guard tally.items > 0 else { return }
        let interval = options.progressInterval
        let (items, bytes) = (tally.items, tally.bytes)
        let report: SpaceScanProgress? = state.withLock { state in
            state.progress.items += items
            state.progress.bytes += bytes
            guard state.progress.items - state.lastReported >= interval else { return nil }
            state.lastReported = state.progress.items
            return state.progress
        }
        tally = Tally()
        if let report { continuation?.yield(report) }
    }

    func recordUnreadable(_ path: String) {
        let limit = options.unreadableLimit
        state.withLock { state in
            state.progress.unreadable += 1
            if state.unreadable.count < limit { state.unreadable.append(path) }
        }
    }

    func recordOtherVolume(_ path: String) {
        state.withLock { $0.otherVolumes.append(path) }
    }

    func finish() -> (unreadable: [String], unreadableCount: Int, otherVolumes: [String]) {
        let final = state.withLock { $0 }
        continuation?.yield(final.progress)
        return (final.unreadable.sorted(), final.progress.unreadable, final.otherVolumes.sorted())
    }
}
