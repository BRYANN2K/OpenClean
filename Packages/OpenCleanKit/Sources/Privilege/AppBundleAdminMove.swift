import Darwin
import Foundation
import ProcessKit
import RuleKit

public enum AppBundleAdminMoveError: Error, Sendable, Equatable, CustomStringConvertible {
    case sourceNotCanonical
    case sourceHasSymlink
    case sourceMissing
    case notAnAppBundle
    case outsideApplicationFolders
    case systemLocation
    case unreadableBundleID
    case bundleIDMismatch
    case appleApp
    case openClean
    case destinationNotCanonical
    case destinationOutsideSession
    case destinationExists
    case destinationNameMismatch
    case rootUser
    case stagingUnavailable
    case differentVolume
    case sourceChanged
    case bundleNotSealed

    public var description: String {
        switch self {
        case .sourceNotCanonical: "the app's path is not canonical"
        case .sourceHasSymlink: "the app's path goes through a symbolic link"
        case .sourceMissing: "the app is no longer there"
        case .notAnAppBundle: "this is not an application bundle"
        case .outsideApplicationFolders: "only apps directly inside an Applications folder can be uninstalled"
        case .systemLocation: "apps in /System are part of macOS and are never removed"
        case .unreadableBundleID: "the app's bundle identifier could not be read"
        case .bundleIDMismatch: "the app's bundle identifier changed since it was listed"
        case .appleApp: "Apple apps are part of macOS and are never removed"
        case .openClean: "OpenClean can't uninstall itself"
        case .destinationNotCanonical: "the quarantine location is not canonical"
        case .destinationOutsideSession: "the quarantine location is outside this session"
        case .destinationExists: "something is already at the quarantine location"
        case .destinationNameMismatch: "the quarantine location doesn't match the app's name"
        case .rootUser: "OpenClean is running as root"
        case .stagingUnavailable: "the system staging folder (/private/var/tmp) is not safe to use"
        case .differentVolume: "the app, quarantine and /private/var/tmp are not all on the same volume"
        case .sourceChanged: "the app changed since it was checked"
        case .bundleNotSealed:
            "the app contains folders you own or can change, so it can't be moved safely as an administrator"
        }
    }
}

/// The one root command the Uninstaller may run: move a single app bundle the user can't move out of its
/// Applications folder into a fresh root-only staging folder, give it to the user there, and hand the
/// folder over. The current user (not root) then moves the bundle into the quarantine session
/// (`finishAsUser`).
///
/// Renders exactly (every word single-quoted; `<T>` is `stagingDirectory`, `<B>` is `stagingBundle`):
///
///     '/bin/mkdir' '-m' '700' '--' '<T>'
///     && { '/bin/mv' '-n' '--' '<source>' '<B>' || { '/bin/rmdir' '--' '<T>'; false; }; }
///     && [ "$('/usr/bin/stat' '-f' '%d:%i' '<B>')" = '<device>:<inode>' ]
///     && '/usr/bin/find' '<B>' '(' '-type' 'd' '-o' '(' '-type' 'f' '-o' '-type' 'l' ')' '-links' '1' ')'
///        '-exec' '/usr/sbin/chown' '-h' '--' '<uid>:<gid>' '{}' '+'
///     && '/usr/sbin/chown' '-h' '--' '<uid>:<gid>' '<T>'
///
/// Why this shape: root never touches a path the user can create, replace or still reach while the
/// password prompt is open.
/// - `<T>` is a new directory under root-owned, sticky `/private/var/tmp` (`mkdir` fails if anything,
///   even a symlink, already has the name), mode 0700 and owned by root, so nobody else can enter it.
/// - The bundle is renamed into `<T>` first. Its device and inode must equal the ones validated at
///   construction, so a bundle swapped in the Applications folder (or a cross-volume copy by `mv`) is never
///   chowned; it stays root-owned in `<T>`.
/// - The bundle must be "sealed" when the prompt is shown (`sealProblem`: no folder in it is owned or
///   writable by the user), so its contents can't change during the chown.
/// - Only directories, and regular files and symlinks with exactly one link, are chowned (`-h`: never
///   through a symlink). A file with more than one hard link could be a link to a file elsewhere, so it
///   stays root-owned (it is still inside the user-owned quarantine folder, so purge can remove it).
/// - The quarantine `destination` (inside the user-writable session folder) never appears in the script.
/// Nothing the user types ever reaches the shell.
public struct AppBundleAdminMove: Sendable, Equatable {
    public static let openCleanBundleID = "com.openclean"
    /// Root-owned, sticky, on the data volume. The staging folder is created directly inside it.
    public static let stagingBase = "/private/var/tmp"

    public let source: String
    public let destination: String
    /// `<stagingBase>/openclean-uninstall.<random>`: created by root in the script, then handed to the user.
    public let stagingDirectory: String
    /// Where the bundle sits between the root script and `finishAsUser`.
    public var stagingBundle: String { stagingDirectory + "/" + Self.split(source).name }
    public let sourceDevice: Int32
    public let sourceInode: UInt64
    public let uid: uid_t
    public let gid: gid_t

    /// - Parameters:
    ///   - source: the app bundle; canonical, symlink-free, a `.app` directory directly inside one of
    ///     `applicationFolders`, not in `/System`, with `bundleID` (not Apple's, not OpenClean's) on disk.
    ///   - destination: `<sessionItemsDirectory>/<n>/<same name as source>`; must not exist yet, and its
    ///     parent must already exist (created by the caller as the user).
    ///   - applicationFolders: folders an app may be uninstalled from (normally `/Applications`).
    ///   - sessionItemsDirectory: the `items/` folder of the quarantine session being written.
    ///   - protectedPaths: OpenClean's own bundle; the source may not be it, inside it or contain it.
    ///
    /// The source, the staging base and the session must be on the same volume (`mv` would copy otherwise).
    public init(
        source: String, destination: String, bundleID: String, applicationFolders: [String],
        sessionItemsDirectory: String, protectedPaths: [String] = []
    ) throws {
        let uid = getuid()
        guard uid != 0 else { throw AppBundleAdminMoveError.rootUser }
        try Self.validateSource(
            source, bundleID: bundleID, applicationFolders: applicationFolders, protectedPaths: protectedPaths)
        try Self.validateDestination(destination, source: source, sessionItemsDirectory: sessionItemsDirectory)
        guard let sourceStat = FileStat.of(source) else { throw AppBundleAdminMoveError.sourceMissing }
        try Self.validateStagingBase(device: sourceStat.device, items: sessionItemsDirectory)
        self.source = source
        self.destination = destination
        self.stagingDirectory = Self.stagingBase + "/openclean-uninstall." + UUID().uuidString
        self.sourceDevice = sourceStat.device
        self.sourceInode = sourceStat.inode
        self.uid = uid
        self.gid = getgid()
    }

    /// Shell text for `do shell script`. Every value is single-quoted; the only unquoted text is fixed here.
    public var shellText: String {
        func words(_ argv: [String]) -> String { argv.map(AdminCommandBuilder.shellQuote).joined(separator: " ") }
        let owner = "\(uid):\(gid)"
        let identity = "\(sourceDevice):\(sourceInode)"
        let makeStaging = words(["/bin/mkdir", "-m", "700", "--", stagingDirectory])
        let move = words(["/bin/mv", "-n", "--", source, stagingBundle])
        let removeStaging = words(["/bin/rmdir", "--", stagingDirectory])
        let stat = words(["/usr/bin/stat", "-f", "%d:%i", stagingBundle])
        let chownContents = words([
            "/usr/bin/find", stagingBundle, "(", "-type", "d", "-o", "(", "-type", "f", "-o", "-type", "l", ")",
            "-links", "1", ")", "-exec", "/usr/sbin/chown", "-h", "--", owner, "{}", "+",
        ])
        let chownStaging = words(["/usr/sbin/chown", "-h", "--", owner, stagingDirectory])
        return [
            makeStaging,
            "{ \(move) || { \(removeStaging); false; }; }",
            "[ \"$(\(stat))\" = \(AdminCommandBuilder.shellQuote(identity)) ]",
            chownContents,
            chownStaging,
        ].joined(separator: " && ")
    }

    /// Why prompting would be unsafe right now, or nil. A bundle with a folder the user owns or can write
    /// to could be changed (even through a descriptor opened earlier) while root chowns it, so such a
    /// bundle is never moved as root. Checked by the executor just before the prompt.
    public func sealProblem() -> String? {
        guard let top = FileStat.of(source), top.isDirectory, !top.isSymlink,
            top.device == sourceDevice, top.inode == sourceInode
        else { return AppBundleAdminMoveError.sourceChanged.description }
        func unsafe(_ path: String) -> Bool {
            guard let stat = FileStat.of(path) else { return true }
            return stat.ownerUID == uid || access(path, W_OK) == 0
        }
        if unsafe(source) { return AppBundleAdminMoveError.bundleNotSealed.description }
        // A folder that can't be listed can't be checked: fail closed.
        let unreadable = UnreadableFlag()
        guard
            let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: source, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [],
                errorHandler: { _, _ in
                    unreadable.set()
                    return false
                })
        else { return AppBundleAdminMoveError.bundleNotSealed.description }
        var failed = false
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                failed = true
                break
            }
            if values.isDirectory == true && values.isSymbolicLink != true && unsafe(url.path) {
                failed = true
                break
            }
        }
        return failed || unreadable.isSet ? AppBundleAdminMoveError.bundleNotSealed.description : nil
    }

    /// Runs as the current user after the root script: moves the staged bundle (identified by the device
    /// and inode validated at construction) into `destination` without replacing anything, then removes
    /// the empty staging folder. Never touches a staged bundle that isn't the user's or isn't the original.
    ///
    /// If the final move fails, the bundle is left in `stagingBundle` (owned by the user, so they can drag it
    /// back) and `.stranded` says where it is. It is not moved back to the Applications folder: that would
    /// need root again.
    public func finishAsUser() -> AppBundleAdminFinish {
        guard let staged = FileStat.of(stagingBundle) else {
            if let current = FileStat.of(source), current.device == sourceDevice, current.inode == sourceInode {
                return .notMoved
            }
            return .stranded(
                "the app is no longer at \(source) and was not found at \(stagingBundle)")
        }
        guard staged.isDirectory, !staged.isSymlink, staged.device == sourceDevice, staged.inode == sourceInode
        else {
            return .stranded("something other than the app is at \(stagingBundle); the app was not moved")
        }
        guard staged.ownerUID == uid, let folder = FileStat.of(stagingDirectory), folder.isDirectory,
            !folder.isSymlink, folder.ownerUID == uid
        else {
            return .stranded(
                "the app was moved to \(stagingBundle) but is not yours yet; an administrator must move it back")
        }
        // Moving a directory to another folder needs write access to it (its ".." entry changes).
        var info = Darwin.stat()
        guard lstat(stagingBundle, &info) == 0 else {
            return .stranded("the app is at \(stagingBundle) but could not be read")
        }
        let mode = info.st_mode & 0o7777
        let needsWrite = mode & S_IWUSR == 0
        if needsWrite { chmod(stagingBundle, mode | S_IWUSR) }
        // RENAME_EXCL: fails (EEXIST) instead of replacing or entering anything already at the destination.
        guard renamex_np(stagingBundle, destination, UInt32(RENAME_EXCL)) == 0 else {
            let reason = String(cString: strerror(errno))
            if needsWrite { chmod(stagingBundle, mode) }
            return .stranded(
                "the app was moved to \(stagingBundle) but could not be put into quarantine (\(reason)); "
                    + "it is still there, yours to move back")
        }
        if needsWrite { chmod(destination, mode) }
        rmdir(stagingDirectory)
        return .moved
    }

    // MARK: Validation

    static func validateSource(
        _ path: String, bundleID: String, applicationFolders: [String], protectedPaths: [String]
    ) throws {
        guard AdminCommandBuilder.isCanonicalAbsolute(path), !hasNonCanonicalComponent(path) else {
            throw AppBundleAdminMoveError.sourceNotCanonical
        }
        if pathIsWithin(path, "/System", caseInsensitive: true) { throw AppBundleAdminMoveError.systemLocation }
        try requireNoSymlinks(path, missing: .sourceMissing, symlink: .sourceHasSymlink)
        guard let stat = FileStat.of(path), stat.isDirectory else { throw AppBundleAdminMoveError.notAnAppBundle }

        let (parent, name) = split(path)
        let suffix = Array(".app".utf8)
        let nameKey = canonicalPathKey("/" + name).dropFirst()
        guard nameKey.count > suffix.count, nameKey.suffix(suffix.count).elementsEqual(suffix) else {
            throw AppBundleAdminMoveError.notAnAppBundle
        }
        let parentKey = canonicalPathKey(parent)
        let allowed = applicationFolders.contains { folder in
            guard AdminCommandBuilder.isCanonicalAbsolute(folder), let resolved = realPath(folder) else {
                return false
            }
            return canonicalPathKey(resolved) == parentKey
        }
        guard allowed else { throw AppBundleAdminMoveError.outsideApplicationFolders }

        for protected in protectedPaths {
            let resolved = realPath(protected) ?? protected
            if pathIsWithin(path, resolved, caseInsensitive: true)
                || pathIsWithin(resolved, path, caseInsensitive: true)
            {
                throw AppBundleAdminMoveError.openClean
            }
        }
        if Self.isApple(bundleID) { throw AppBundleAdminMoveError.appleApp }
        if bundleID.lowercased() == openCleanBundleID.lowercased() { throw AppBundleAdminMoveError.openClean }

        // The identifier on disk must be the one the user saw (and pass the same checks).
        let plist = path + "/Contents/Info.plist"
        guard let plistStat = FileStat.of(plist), !plistStat.isSymlink, !plistStat.isDirectory,
            let data = FileManager.default.contents(atPath: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let onDisk = info["CFBundleIdentifier"] as? String, !onDisk.isEmpty
        else { throw AppBundleAdminMoveError.unreadableBundleID }
        if Self.isApple(onDisk) { throw AppBundleAdminMoveError.appleApp }
        if onDisk.lowercased() == openCleanBundleID.lowercased() { throw AppBundleAdminMoveError.openClean }
        guard onDisk == bundleID else { throw AppBundleAdminMoveError.bundleIDMismatch }
    }

    static func validateDestination(_ path: String, source: String, sessionItemsDirectory items: String) throws {
        guard AdminCommandBuilder.isCanonicalAbsolute(path), !hasNonCanonicalComponent(path),
            AdminCommandBuilder.isCanonicalAbsolute(items), !hasNonCanonicalComponent(items)
        else { throw AppBundleAdminMoveError.destinationNotCanonical }
        // The items folder must be exactly where it says (no symlink anywhere on the way).
        guard let resolvedItems = realPath(items), Array(resolvedItems.utf8) == Array(items.utf8),
            FileStat.of(items)?.isDirectory == true, split(items).name == "items"
        else { throw AppBundleAdminMoveError.destinationOutsideSession }
        guard pathIsWithin(path, items, caseInsensitive: true),
            canonicalPathKey(path) != canonicalPathKey(items)
        else { throw AppBundleAdminMoveError.destinationOutsideSession }

        let (parent, name) = split(path)
        guard canonicalPathKey(name) == canonicalPathKey(split(source).name) else {
            throw AppBundleAdminMoveError.destinationNameMismatch
        }
        // `mv` into an existing directory (or a symlink to one) would put the app somewhere else.
        var info = Darwin.stat()
        if lstat(path, &info) == 0 || errno != ENOENT { throw AppBundleAdminMoveError.destinationExists }
        guard let resolvedParent = realPath(parent), Array(resolvedParent.utf8) == Array(parent.utf8),
            FileStat.of(parent)?.isDirectory == true,
            pathIsWithin(parent, items, caseInsensitive: true)
        else { throw AppBundleAdminMoveError.destinationOutsideSession }
    }

    /// The staging base must be root-owned, sticky (or not writable by the user), symlink-free, and on the
    /// same volume as the source and the session, so every move is a rename and never a copy.
    static func validateStagingBase(device: Int32, items: String) throws {
        let base = stagingBase
        try requireNoSymlinks(base, missing: .stagingUnavailable, symlink: .stagingUnavailable)
        var info = Darwin.stat()
        guard lstat(base, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == 0,
            info.st_mode & S_ISVTX != 0 || access(base, W_OK) != 0
        else { throw AppBundleAdminMoveError.stagingUnavailable }
        guard info.st_dev == device, FileStat.of(items)?.device == device else {
            throw AppBundleAdminMoveError.differentVolume
        }
    }

    /// Every component from the root down must exist and not be a symlink.
    static func requireNoSymlinks(
        _ path: String, missing: AppBundleAdminMoveError, symlink: AppBundleAdminMoveError
    ) throws {
        let bytes = Array(path.utf8)
        var ends = bytes.indices.filter { $0 > 0 && bytes[$0] == 0x2F }
        ends.append(bytes.count)
        for end in ends {
            let prefix = String(decoding: bytes[..<end], as: UTF8.self)
            guard let stat = FileStat.of(prefix) else { throw missing }
            if stat.isSymlink { throw symlink }
        }
        guard let resolved = realPath(path), Array(resolved.utf8) == bytes else { throw symlink }
    }

    static func split(_ path: String) -> (parent: String, name: String) {
        let bytes = Array(path.utf8)
        guard let slash = bytes.lastIndex(of: 0x2F) else { return ("", path) }
        let parent = slash == 0 ? "/" : String(decoding: bytes[..<slash], as: UTF8.self)
        return (parent, String(decoding: bytes[(slash + 1)...], as: UTF8.self))
    }

    static func isApple(_ bundleID: String) -> Bool { bundleID.lowercased().starts(with: "com.apple.") }
}

private final class UnreadableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// What `AppBundleAdminMove.finishAsUser` found and did.
public enum AppBundleAdminFinish: Sendable, Equatable {
    /// The bundle is at `destination`; the staging folder was removed.
    case moved
    /// Nothing was staged and the original bundle is still in place.
    case notMoved
    /// The bundle is not in place and not in quarantine; the text says where it is (for the user).
    case stranded(String)
}

/// Runs the Uninstaller's one root command. Accepts nothing but `AppBundleAdminMove`.
public protocol AppBundleAdminExecutor: Sendable {
    func runAsAdmin(_ move: AppBundleAdminMove) -> AdminRunOutcome
}

extension OsascriptAdminExecutor: AppBundleAdminExecutor {
    /// One standard administrator prompt per call; no timeout (a human types the password). No prompt is
    /// shown for a bundle that isn't sealed against the user (`sealProblem`).
    public func runAsAdmin(_ move: AppBundleAdminMove) -> AdminRunOutcome {
        if let problem = move.sealProblem() { return .failed(problem) }
        return runPrompted(move.shellText)
    }
}
