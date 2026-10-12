import Foundation
import RuleKit
import os

/// Remembers multiply-linked files so each is counted once per scan.
public final class HardLinkLedger: Sendable {
    private struct Key: Hashable, Sendable {
        let device: Int32
        let inode: UInt64
    }

    private let claimed = OSAllocatedUnfairLock(initialState: Set<Key>())

    public init() {}

    /// True the first time a given (device, inode) is claimed.
    public func claim(device: Int32, inode: UInt64) -> Bool {
        claimed.withLock { $0.insert(Key(device: device, inode: inode)).inserted }
    }
}

public enum FileSizer {
    /// Allocated bytes of a file, or of a directory tree without following symlinks.
    /// Hard-linked files count once per ledger. Stops early if the task is cancelled.
    public static func allocatedSize(of path: String, ledger: HardLinkLedger) -> Int64 {
        guard let root = FileStat.of(path) else { return 0 }
        var total = countable(root, ledger)
        guard root.isDirectory, let enumerator = FileManager.default.enumerator(atPath: path) else {
            return total
        }
        while let relative = enumerator.nextObject() as? String {
            if Task.isCancelled { break }
            if let stat = FileStat.of(path + "/" + relative) {
                total += countable(stat, ledger)
            }
        }
        return total
    }

    private static func countable(_ stat: FileStat, _ ledger: HardLinkLedger) -> Int64 {
        if !stat.isDirectory, stat.linkCount > 1, !ledger.claim(device: stat.device, inode: stat.inode) {
            return 0
        }
        return stat.allocatedBytes
    }
}
