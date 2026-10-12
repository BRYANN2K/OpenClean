import Foundation
import Quarantine

public struct LargeFile: Sendable, Identifiable, Equatable {
    public let snapshot: FileSnapshot
    /// Canonical root of the walk that found it.
    public let scanRoot: String
    public let name: String
    /// Allocated bytes (the whole bundle for VM and disk-image packages).
    public let size: Int64
    public let kind: FileKind
    /// The later of the content access and content modification dates.
    public let lastOpened: Date?
    public let modified: Date
    /// Inside Documents or Desktop: may only be moved by ticking this file.
    public let isUserContent: Bool

    public var id: String { snapshot.path }
    public var path: String { snapshot.path }
}

public struct LargeFileOptions: Sendable, Equatable {
    /// Nothing smaller is collected; filters can only raise this.
    public var minimumSize: Int64
    /// Also walk ~/Documents and ~/Desktop (deny-listed for automatic cleanup).
    public var includeUserContent: Bool
    public var maxConcurrency: Int

    public init(
        minimumSize: Int64 = LargeFileFilter.thresholds[0], includeUserContent: Bool = false,
        maxConcurrency: Int = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
    ) {
        self.minimumSize = minimumSize
        self.includeUserContent = includeUserContent
        self.maxConcurrency = maxConcurrency
    }
}

public struct LargeFileResult: Sendable, Equatable {
    /// Largest first.
    public var files: [LargeFile]
    public var roots: [String]
    public var unreadable: [String]
    public var unreadableCount: Int
    public var isComplete: Bool
}

/// Which large files to show. Changing it never needs a rescan as long as `minimumSize` stays at or
/// above the finder's `LargeFileOptions.minimumSize`.
public struct LargeFileFilter: Sendable, Equatable {
    /// 50 MB, 100 MB, 500 MB, 1 GB (decimal, like Finder).
    public static let thresholds: [Int64] = [50_000_000, 100_000_000, 500_000_000, 1_000_000_000]
    /// "Not opened for" choices in days; nil means any time.
    public static let ageChoices: [Int?] = [nil, 90, 180, 365]

    public var minimumSize: Int64
    public var notOpenedForDays: Int?

    public init(minimumSize: Int64 = 100_000_000, notOpenedForDays: Int? = nil) {
        self.minimumSize = minimumSize
        self.notOpenedForDays = notOpenedForDays
    }

    public func matches(_ file: LargeFile, now: Date = .now) -> Bool {
        guard file.size >= minimumSize else { return false }
        guard let days = notOpenedForDays else { return true }
        let used = file.lastOpened ?? file.modified
        return used <= now.addingTimeInterval(-Double(days) * 86_400)
    }

    public func apply(_ files: [LargeFile], now: Date = .now) -> [LargeFile] {
        files.filter { matches($0, now: now) }
    }

    /// Kinds in `FileKind.allCases` order, each largest first; empty kinds left out.
    public static func grouped(_ files: [LargeFile]) -> [(kind: FileKind, files: [LargeFile])] {
        FileKind.allCases.compactMap { kind in
            let matching = files.filter { $0.kind == kind }
            return matching.isEmpty ? nil : (kind, matching)
        }
    }
}

/// Finds big files in user folders. Reads only.
public struct LargeFileFinder: Sendable {
    public static let measuredPackages: Set<String> = ["sparsebundle", "pvm", "utm", "vmwarevm"]

    let policy: TrashPolicy
    let options: LargeFileOptions

    public init(policy: TrashPolicy, options: LargeFileOptions = LargeFileOptions()) {
        self.policy = policy
        self.options = options
    }

    public func find(roots: [String], progress: AsyncStream<FinderProgress>.Continuation? = nil) async
        -> LargeFileResult
    {
        let normalized = FileWalker.normalizedRoots(roots)
        let walker = FileWalker(
            policy: policy, includeUserContent: options.includeUserContent,
            measuredPackages: Self.measuredPackages, maxConcurrency: options.maxConcurrency)
        let sink = FinderProgressSink(progress)
        let minimum = options.minimumSize
        let policy = policy
        let outcome = await walker.walk(roots: normalized, progress: sink) { item -> LargeFile? in
            guard item.size >= minimum else { return nil }
            let values = try? URL(fileURLWithPath: item.path)
                .resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
            let accessed = values?.contentAccessDate
            let modified = values?.contentModificationDate ?? item.stat.modificationDate
            return LargeFile(
                snapshot: item.stat.snapshot(path: item.path), scanRoot: item.root, name: item.name, size: item.size,
                kind: FileKind(fileName: item.name), lastOpened: max(accessed ?? modified, modified),
                modified: modified, isUserContent: policy.isUserContent(item.path))
        }
        sink.finish()
        // Hard links to one file are listed once.
        var seen = Set<FileIdentity>()
        let files = outcome.items
            .sorted { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
            .filter { seen.insert(FileIdentity($0.snapshot)).inserted }
        return LargeFileResult(
            files: files, roots: normalized, unreadable: outcome.unreadable, unreadableCount: outcome.unreadableCount,
            isComplete: !Task.isCancelled)
    }
}

struct FileIdentity: Hashable {
    let device: Int32
    let inode: UInt64

    init(_ snapshot: FileSnapshot) {
        device = snapshot.device
        inode = snapshot.inode
    }

    init(device: Int32, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}
