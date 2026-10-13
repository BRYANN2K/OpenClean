import Darwin
import Foundation

/// Gives the current user write permission on the folders they own inside an item that is about to be
/// deleted, for rules with `make_writable: true` (Go makes `~/go/pkg/mod` read-only, so a plain delete
/// fails partway). Runs only inside `Remover`, after `PreDeleteChecker` passed.
///
/// Every folder is opened relative to its parent's descriptor with `O_NOFOLLOW`, checked with `fstat`
/// and changed with `fchmod`, so a symlink swapped in during the walk is never followed and nothing
/// outside the item is touched. Only folders owned by the current user, on the item's volume, lacking
/// `u+w` are changed, and only that one bit is added. Files are never changed (deleting a file needs
/// write permission on its folder, not on the file). Folders not owned by the user are left alone, so
/// their removal fails and is reported, as before.
enum WritableTree {
    enum Problem: Error, CustomStringConvertible {
        case changed
        case cannotOpen(String, Int32)
        case tooDeep

        var description: String {
            switch self {
            case .changed: "changed since the scan"
            case .cannotOpen(let path, let code): "could not open \(path): \(String(cString: strerror(code)))"
            case .tooDeep: "folders nested too deeply"
            }
        }
    }

    static let maxDepth = 512

    /// `path` must be the item checked moments ago: a real folder with this device and inode.
    /// A plain file needs nothing and is left as is.
    static func prepare(_ path: String, device: Int32, inode: UInt64) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOTDIR { return }
            throw Problem.cannotOpen(path, errno)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == device, UInt64(info.st_ino) == inode else {
            throw Problem.changed
        }
        try walk(fd, info: info, path: path, device: device, uid: getuid(), depth: 0)
    }

    private static func walk(_ fd: Int32, info: stat, path: String, device: Int32, uid: uid_t, depth: Int) throws {
        guard depth < maxDepth else { throw Problem.tooDeep }
        if info.st_uid == uid && (info.st_mode & S_IWUSR) == 0 {
            // Failure is not fatal: the delete then fails for this folder and is reported.
            _ = fchmod(fd, (info.st_mode & 0o7777) | S_IWUSR)
        }
        // fdopendir takes ownership of its descriptor, so give it a duplicate. The listing is closed before
        // descending, so a deep tree holds one descriptor per level.
        let listing = dup(fd)
        guard listing >= 0, let dir = fdopendir(listing) else {
            if listing >= 0 { close(listing) }
            return
        }
        var children: [String] = []
        while let entry = readdir(dir) {
            let type = Int32(entry.pointee.d_type)
            guard type == DT_DIR || type == DT_UNKNOWN else { continue }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(length), as: UTF8.self)
            }
            if name != "." && name != ".." { children.append(name) }
        }
        closedir(dir)
        for name in children {
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            // Not a folder (DT_UNKNOWN files, symlinks) or unreadable: nothing to do here.
            guard child >= 0 else { continue }
            defer { close(child) }
            var childInfo = stat()
            guard fstat(child, &childInfo) == 0, childInfo.st_dev == device,
                (childInfo.st_mode & S_IFMT) == S_IFDIR
            else { continue }
            try walk(child, info: childInfo, path: path + "/" + name, device: device, uid: uid, depth: depth + 1)
        }
    }
}
