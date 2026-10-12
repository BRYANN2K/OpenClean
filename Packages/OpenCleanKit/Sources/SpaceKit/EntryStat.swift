import Darwin
import Foundation

/// What Space Lens remembers about an item so the Trash action can tell whether it changed.
/// Field semantics match `RuleKit.FileStat` (lstat; modification date with nanoseconds).
public struct FileSnapshot: Sendable, Hashable {
    /// Canonical absolute path.
    public let path: String
    public let device: Int32
    public let inode: UInt64
    public let modificationDate: Date
    public let isDirectory: Bool

    public init(path: String, device: Int32, inode: UInt64, modificationDate: Date, isDirectory: Bool) {
        self.path = path
        self.device = device
        self.inode = inode
        self.modificationDate = modificationDate
        self.isDirectory = isDirectory
    }
}

/// `lstat` result with the fields Space Lens needs (logical size, birth time) on top of `FileStat`'s.
struct EntryStat: Sendable {
    let device: Int32
    let inode: UInt64
    let linkCount: UInt16
    let logicalSize: Int64
    let allocatedBytes: Int64
    let modificationDate: Date
    let birthDate: Date
    let type: mode_t

    var isDirectory: Bool { type == S_IFDIR }
    var isRegular: Bool { type == S_IFREG }
    var isSymlink: Bool { type == S_IFLNK }

    init(_ st: stat) {
        device = st.st_dev
        inode = st.st_ino
        linkCount = st.st_nlink
        logicalSize = Int64(st.st_size)
        allocatedBytes = Int64(st.st_blocks) * 512
        modificationDate = Self.date(st.st_mtimespec)
        birthDate = Self.date(st.st_birthtimespec)
        type = st.st_mode & S_IFMT
    }

    static func date(_ spec: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1_000_000_000)
    }

    /// Never follows a final symlink.
    static func of(_ path: String) -> EntryStat? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return EntryStat(st)
    }

    /// `fstatat` relative to an open directory, without following symlinks.
    static func at(_ directoryFD: Int32, _ name: String) -> EntryStat? {
        var st = stat()
        guard fstatat(directoryFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return EntryStat(st)
    }

    func snapshot(path: String) -> FileSnapshot {
        FileSnapshot(
            path: path, device: device, inode: inode, modificationDate: modificationDate, isDirectory: isDirectory)
    }
}

/// Lists a directory with `opendir`/`readdir`, giving each entry's `lstat` without following symlinks.
enum DirectoryReader {
    struct Entry {
        let name: String
        let stat: EntryStat
    }

    /// Entries of `path` (without "." and ".."), or nil when the directory cannot be opened.
    /// Entries that vanish between listing and `fstatat` are left out.
    static func entries(of path: String) -> [Entry]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        var result: [Entry] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            if let stat = EntryStat.at(fd, name) { result.append(Entry(name: name, stat: stat)) }
        }
        return result
    }
}

/// Joins a directory path and an entry name without doubling the separator at "/".
func joinPath(_ directory: String, _ name: String) -> String {
    directory == "/" ? "/" + name : directory + "/" + name
}

/// An async counting semaphore. Only leaf work acquires a permit, so nested levels can't deadlock.
actor ConcurrencyGate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        available = max(1, limit)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
