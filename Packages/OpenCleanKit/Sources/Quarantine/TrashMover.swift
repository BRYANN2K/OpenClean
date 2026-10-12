import Foundation
import RuleKit

/// One item the user picked to move to the Trash, with the snapshot taken when it was scanned.
public struct TrashRequest: Sendable, Equatable, Hashable {
    /// Canonical (realpath'd) path as scanned.
    public let path: String
    /// Canonical root of the scan that found the item; the item must be strictly inside it.
    public let scanRoot: String
    public let device: Int32
    public let inode: UInt64
    public let modificationDate: Date
    public let isDirectory: Bool
    /// Allocated bytes at scan time, for reporting only.
    public let bytes: Int64

    public init(
        path: String, scanRoot: String, device: Int32, inode: UInt64, modificationDate: Date, isDirectory: Bool,
        bytes: Int64
    ) {
        self.path = path
        self.scanRoot = scanRoot
        self.device = device
        self.inode = inode
        self.modificationDate = modificationDate
        self.isDirectory = isDirectory
        self.bytes = bytes
    }
}

public enum TrashSkipReason: Sendable, Equatable, CustomStringConvertible {
    case protected(String)
    case outsideScanRoot
    case coveredBySelection
    case pathChanged
    case missing
    case changedSinceScan
    case inUse
    case openFilesUnknown

    public var description: String {
        switch self {
        case .protected(let reason): "protected (\(reason))"
        case .outsideScanRoot: "not inside the scanned folder"
        case .coveredBySelection: "inside another selected folder"
        case .pathChanged: "its location changed since the scan"
        case .missing: "no longer exists"
        case .changedSinceScan: "changed since the scan"
        case .inUse: "open in another app"
        case .openFilesUnknown: "could not check for open files"
        }
    }
}

public enum TrashOutcome: Sendable, Equatable {
    /// Moved; carries where the Trash put it when known.
    case trashed(String?)
    case skipped(TrashSkipReason)
    case failed(String)
}

public struct TrashItemResult: Sendable, Equatable {
    public let request: TrashRequest
    public let outcome: TrashOutcome
}

public struct TrashReport: Sendable, Equatable {
    public let results: [TrashItemResult]

    public init(results: [TrashItemResult]) {
        self.results = results
    }

    public var trashed: [TrashRequest] {
        results.compactMap { if case .trashed = $0.outcome { $0.request } else { nil } }
    }
    public var notMoved: [TrashItemResult] {
        results.filter { if case .trashed = $0.outcome { false } else { true } }
    }
    public var trashedBytes: Int64 { trashed.reduce(0) { $0 + $1.bytes } }
}

/// Moves user-picked items to the Trash after re-checking each one. Never fails open: anything it cannot
/// verify is skipped and reported.
public struct TrashMover: Sendable {
    let policy: TrashPolicy
    /// Canonical keys of open paths plus all their ancestors; nil when open files could not be determined.
    let busy: Set<[UInt8]>?
    let trash: TrashOperation

    public init(policy: TrashPolicy, openPaths: Set<String>?, trash: @escaping TrashOperation = Remover.systemTrash) {
        self.policy = policy
        self.trash = trash
        guard let openPaths else {
            busy = nil
            return
        }
        var expanded = Set<[UInt8]>()
        for path in openPaths {
            expanded.insert(canonicalPathKey(path))
            expanded.formUnion(canonicalAncestorKeys(path))
        }
        busy = expanded
    }

    /// Why `request` must not be moved, or nil when it may be.
    public func check(_ request: TrashRequest) -> TrashSkipReason? {
        if let reason = policy.verdict(for: request.path, isDirectory: request.isDirectory).refusal {
            return .protected(reason)
        }
        guard request.scanRoot.utf8.first == 0x2F, !hasNonCanonicalComponent(request.scanRoot),
            pathIsWithin(request.path, request.scanRoot, caseInsensitive: true),
            canonicalPathKey(request.path) != canonicalPathKey(request.scanRoot)
        else { return .outsideScanRoot }
        // Only the parent is resolved; the item itself is lstat'd and never followed, so a symlink (even a
        // dangling one) is moved as the link, never its target.
        guard let (parentPath, name) = Self.splitLast(request.path), !name.isEmpty, name != ".", name != ".."
        else { return .pathChanged }
        guard let stat = FileStat.of(request.path) else { return .missing }
        guard let resolvedParent = realPath(parentPath),
            canonicalPathKey(resolvedParent) == canonicalPathKey(parentPath)
        else { return .pathChanged }
        if stat.inode != request.inode || stat.device != request.device
            || stat.modificationDate != request.modificationDate || stat.isDirectory != request.isDirectory
        {
            return .changedSinceScan
        }
        if let parentStat = FileStat.of(parentPath), parentStat.device != stat.device {
            return .protected("a mounted volume")
        }
        guard let busy else { return .openFilesUnknown }
        if busy.contains(canonicalPathKey(request.path)) { return .inUse }
        return nil
    }

    /// `/a/b/c` → (`/a/b`, `c`); `/c` → (`/`, `c`). Split on bytes; nil for relative paths.
    static func splitLast(_ path: String) -> (parent: String, name: String)? {
        let bytes = Array(path.utf8)
        guard bytes.first == 0x2F, let slash = bytes.lastIndex(of: 0x2F) else { return nil }
        let parent = slash == 0 ? "/" : String(decoding: bytes[..<slash], as: UTF8.self)
        return (parent, String(decoding: bytes[(slash + 1)...], as: UTF8.self))
    }

    public func move(_ requests: [TrashRequest]) -> TrashReport {
        let verdicts = requests.map(check)
        // Folders that will be moved carry everything inside them; their contents are not moved separately.
        let folders = zip(requests, verdicts).filter { $0.0.isDirectory && $0.1 == nil }
            .map { canonicalPathKey($0.0.path) }
        var results: [TrashItemResult] = []
        for (request, verdict) in zip(requests, verdicts) {
            if let reason = verdict {
                results.append(TrashItemResult(request: request, outcome: .skipped(reason)))
                continue
            }
            let key = canonicalPathKey(request.path)
            if folders.contains(where: { $0 != key && TrashPolicy.isWithin(key, $0) }) {
                results.append(TrashItemResult(request: request, outcome: .skipped(.coveredBySelection)))
                continue
            }
            do {
                let location = try trash(request.path)
                results.append(TrashItemResult(request: request, outcome: .trashed(location)))
            } catch {
                results.append(TrashItemResult(request: request, outcome: .failed(error.localizedDescription)))
            }
        }
        return TrashReport(results: results)
    }
}
