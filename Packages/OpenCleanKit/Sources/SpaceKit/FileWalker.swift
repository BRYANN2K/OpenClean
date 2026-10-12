import Foundation
import Quarantine
import RuleKit
import ScanEngine
import os

/// Progress of the large-file and duplicate finders.
public struct FinderProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case walking, comparing
    }

    public var phase: Phase
    /// Files looked at while walking.
    public var files: Int
    /// Allocated bytes of the files looked at.
    public var bytes: Int64
    /// Files hashed so far / to hash (duplicates only).
    public var compared: Int
    public var toCompare: Int

    public init(phase: Phase = .walking, files: Int = 0, bytes: Int64 = 0, compared: Int = 0, toCompare: Int = 0) {
        self.phase = phase
        self.files = files
        self.bytes = bytes
        self.compared = compared
        self.toCompare = toCompare
    }
}

/// One item a walk turned up.
struct WalkedItem: Sendable {
    let path: String
    let name: String
    let stat: EntryStat
    /// Allocated bytes (the whole tree for measured packages).
    let size: Int64
    let root: String
}

struct WalkOutcome<T: Sendable>: Sendable {
    var items: [T] = []
    var unreadable: [String] = []
    var unreadableCount = 0
}

/// Walks user folders for the finders. Descends only where `TrashPolicy` would allow moving a child,
/// never follows symlinks, and stays on each root's volume.
struct FileWalker: Sendable {
    let policy: TrashPolicy
    let includeUserContent: Bool
    /// Package folders reported as single items instead of being skipped (VM and disk image bundles).
    let measuredPackages: Set<String>
    let maxConcurrency: Int
    let unreadableLimit = 200

    func mayDescend(into directory: String) -> Bool {
        switch policy.subtreeVerdict(of: directory) {
        case .allowed: true
        case .allowedUserContent: includeUserContent
        case .refused: false
        }
    }

    func mayReport(_ path: String, isDirectory: Bool) -> Bool {
        switch policy.verdict(for: path, isDirectory: isDirectory) {
        case .allowed: true
        case .allowedUserContent: includeUserContent
        case .refused: false
        }
    }

    /// Canonical, existing roots with nested duplicates removed.
    static func normalizedRoots(_ roots: [String]) -> [String] {
        let resolved = roots.compactMap(realPath)
        var result: [String] = []
        for root in resolved.sorted(by: { $0.utf8.count < $1.utf8.count })
        where !result.contains(where: { pathIsWithin(root, $0, caseInsensitive: true) }) {
            result.append(root)
        }
        return result
    }

    /// Calls `transform` for every reportable regular file (and measured package) under `roots`.
    func walk<T: Sendable>(
        roots: [String], progress: FinderProgressSink, transform: @escaping @Sendable (WalkedItem) -> T?
    ) async -> WalkOutcome<T> {
        let sink = WalkSink<T>(unreadableLimit: unreadableLimit)
        let gate = ConcurrencyGate(limit: maxConcurrency)
        for root in roots {
            guard !Task.isCancelled, let rootStat = EntryStat.of(root), rootStat.isDirectory, mayDescend(into: root)
            else { continue }
            guard let entries = DirectoryReader.entries(of: root) else {
                sink.unreadable(root)
                continue
            }
            var subfolders: [(String, EntryStat)] = []
            for entry in entries {
                let path = joinPath(root, entry.name)
                if entry.stat.isDirectory, !isMeasuredPackage(entry.name) {
                    if entry.stat.device == rootStat.device { subfolders.append((path, entry.stat)) }
                } else {
                    visit(
                        path: path, name: entry.name, stat: entry.stat, root: root, sink: sink, progress: progress,
                        transform: transform)
                }
            }
            await withTaskGroup(of: Void.self) { group in
                for (path, _) in subfolders {
                    group.addTask {
                        await gate.acquire()
                        walkTree(
                            path, device: rootStat.device, root: root, sink: sink, progress: progress,
                            transform: transform)
                        await gate.release()
                    }
                }
            }
        }
        return sink.outcome()
    }

    private func walkTree<T: Sendable>(
        _ directory: String, device: Int32, root: String, sink: WalkSink<T>, progress: FinderProgressSink,
        transform: @Sendable (WalkedItem) -> T?
    ) {
        guard !Task.isCancelled, mayDescend(into: directory) else { return }
        guard let entries = DirectoryReader.entries(of: directory) else {
            sink.unreadable(directory)
            return
        }
        for entry in entries {
            let path = joinPath(directory, entry.name)
            if entry.stat.isDirectory, !isMeasuredPackage(entry.name) {
                if entry.stat.device == device {
                    walkTree(path, device: device, root: root, sink: sink, progress: progress, transform: transform)
                }
            } else {
                visit(
                    path: path, name: entry.name, stat: entry.stat, root: root, sink: sink, progress: progress,
                    transform: transform)
            }
        }
    }

    private func visit<T: Sendable>(
        path: String, name: String, stat: EntryStat, root: String, sink: WalkSink<T>, progress: FinderProgressSink,
        transform: @Sendable (WalkedItem) -> T?
    ) {
        if stat.isDirectory {
            // A measured package: report the whole bundle as one item.
            guard mayReport(path, isDirectory: true) else { return }
            let size = FileSizer.allocatedSize(of: path, ledger: HardLinkLedger())
            progress.saw(bytes: size)
            if let item = transform(WalkedItem(path: path, name: name, stat: stat, size: size, root: root)) {
                sink.append(item)
            }
            return
        }
        guard stat.isRegular else { return }
        progress.saw(bytes: stat.allocatedBytes)
        guard mayReport(path, isDirectory: false) else { return }
        if let item = transform(WalkedItem(path: path, name: name, stat: stat, size: stat.allocatedBytes, root: root)) {
            sink.append(item)
        }
    }

    private func isMeasuredPackage(_ name: String) -> Bool {
        measuredPackages.contains((name as NSString).pathExtension.lowercased())
    }
}

/// Thread-safe collector for a walk's results.
final class WalkSink<T: Sendable>: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: WalkOutcome<T>())
    let unreadableLimit: Int

    init(unreadableLimit: Int) {
        self.unreadableLimit = unreadableLimit
    }

    func append(_ item: T) {
        state.withLock { $0.items.append(item) }
    }

    func unreadable(_ path: String) {
        let limit = unreadableLimit
        state.withLock { state in
            state.unreadableCount += 1
            if state.unreadable.count < limit { state.unreadable.append(path) }
        }
    }

    func outcome() -> WalkOutcome<T> {
        var outcome = state.withLock { $0 }
        outcome.unreadable.sort()
        return outcome
    }
}

/// Counts what the finders have looked at and forwards throttled updates to an AsyncStream.
final class FinderProgressSink: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (progress: FinderProgress(), lastReported: 0))
    private let continuation: AsyncStream<FinderProgress>.Continuation?
    private let interval: Int

    init(_ continuation: AsyncStream<FinderProgress>.Continuation?, interval: Int = 500) {
        self.continuation = continuation
        self.interval = interval
    }

    func saw(bytes: Int64) {
        let interval = interval
        let report: FinderProgress? = state.withLock { state in
            state.progress.files += 1
            state.progress.bytes += bytes
            guard state.progress.files - state.lastReported >= interval else { return nil }
            state.lastReported = state.progress.files
            return state.progress
        }
        if let report { continuation?.yield(report) }
    }

    func comparing(done: Int, total: Int) {
        let report = state.withLock { state -> FinderProgress in
            state.progress.phase = .comparing
            state.progress.compared = done
            state.progress.toCompare = total
            return state.progress
        }
        continuation?.yield(report)
    }

    func finish() {
        continuation?.yield(state.withLock { $0.progress })
    }
}

/// Runs `transform` over `items` with at most `limit` running at once, keeping input order.
func concurrentMap<T: Sendable, R: Sendable>(
    _ items: [T], limit: Int, _ transform: @escaping @Sendable (T) -> R
) async -> [R] {
    guard !items.isEmpty else { return [] }
    var results = [R?](repeating: nil, count: items.count)
    await withTaskGroup(of: (Int, R).self) { group in
        var next = 0
        for _ in 0..<min(max(1, limit), items.count) {
            let index = next
            group.addTask { (index, transform(items[index])) }
            next += 1
        }
        for await (index, result) in group {
            results[index] = result
            if next < items.count {
                let index = next
                group.addTask { (index, transform(items[index])) }
                next += 1
            }
        }
    }
    return results.map { $0! }
}
