import Darwin
import Foundation

/// Canonical absolute path with every symlink resolved, or nil if the path does not exist.
public func realPath(_ path: String) -> String? {
    guard let resolved = Darwin.realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// `lstat` snapshot of a path. Never follows a final symlink.
public struct FileStat: Sendable, Equatable {
    public let device: Int32
    public let inode: UInt64
    public let linkCount: UInt16
    public let ownerUID: UInt32
    /// Allocated bytes on disk (st_blocks * 512); sparse regions are not counted.
    public let allocatedBytes: Int64
    public let modificationDate: Date
    public let isDirectory: Bool
    public let isSymlink: Bool

    public static func of(_ path: String) -> FileStat? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        let seconds = TimeInterval(st.st_mtimespec.tv_sec)
        let nanos = TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
        return FileStat(
            device: st.st_dev,
            inode: st.st_ino,
            linkCount: st.st_nlink,
            ownerUID: st.st_uid,
            allocatedBytes: Int64(st.st_blocks) * 512,
            modificationDate: Date(timeIntervalSince1970: seconds + nanos),
            isDirectory: type == S_IFDIR,
            isSymlink: type == S_IFLNK
        )
    }
}

/// "/"-separated components, split on UTF-8 bytes so a combining mark after "/" cannot merge
/// separators into a single Character and hide a component.
func pathComponents(_ path: String) -> [String] {
    path.utf8.split(separator: 0x2F, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
}

/// Removes duplicate and trailing slashes. Does not touch `/private` (unlike `standardizingPath`).
func normalizedPath(_ path: String) -> String {
    var bytes: [UInt8] = []
    for part in path.utf8.split(separator: 0x2F, omittingEmptySubsequences: true) {
        bytes.append(0x2F)
        bytes.append(contentsOf: part)
    }
    return bytes.isEmpty ? "/" : String(decoding: bytes, as: UTF8.self)
}

/// Byte form of `ancestorOrEqual`: `ancestor` equals `path` or is a parent directory of it.
func isAncestorOrEqual(_ a: [UInt8], of p: [UInt8]) -> Bool {
    if a == [0x2F] { return true }
    if p.count == a.count { return p == a }
    return p.count > a.count && p.starts(with: a) && p[a.count] == 0x2F
}

/// True when `ancestor` equals `path` or is one of its parent directories. Compares UTF-8 bytes.
func isAncestorOrEqual(_ ancestor: String, of path: String) -> Bool {
    isAncestorOrEqual(Array(ancestor.utf8), of: Array(path.utf8))
}

/// Case-insensitive, canonical-equivalence-insensitive comparison key (APFS treats NFC/NFD names as
/// the same). Folds case first, then decomposes, so the result is stable. "/" is never altered.
func pathKey(_ s: String) -> [UInt8] {
    Array(s.folding(options: [.caseInsensitive], locale: nil).decomposedStringWithCanonicalMapping.utf8)
}

/// True when `path` equals `root` or is inside it, comparing UTF-8 bytes. `root` may carry trailing
/// or duplicate slashes. With `caseInsensitive`, compares `pathKey`s.
public func pathIsWithin(_ path: String, _ root: String, caseInsensitive: Bool = false) -> Bool {
    let r = normalizedPath(root)
    let p = normalizedPath(path)
    return caseInsensitive
        ? isAncestorOrEqual(pathKey(r), of: pathKey(p))
        : isAncestorOrEqual(r, of: p)
}

/// True if any "/"-separated component is exactly "." or "..". Works on UTF-8 bytes so a combining
/// mark after "/" cannot merge separators into a single Character and hide a component.
func hasNonCanonicalComponent(_ path: String) -> Bool {
    path.utf8.split(separator: 0x2F).contains { $0.elementsEqual([0x2E]) || $0.elementsEqual([0x2E, 0x2E]) }
}
