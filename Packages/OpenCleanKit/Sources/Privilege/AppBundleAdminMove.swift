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
        }
    }
}

/// The one root command the Uninstaller may run: move a single app bundle the user can't move into the
/// current quarantine session, then make the quarantined copy the user's so restore and purge need no root.
///
/// Renders exactly `/bin/mv -n -- <source> <destination> && /usr/sbin/chown -R -- <uid>:<gid> <destination>`
/// (every word single-quoted; `chown -R` follows no symlinks by default). There is no other shape: both
/// executables, all flags and the uid/gid are fixed here, and the two paths pass `validate` at construction.
/// Nothing the user types ever reaches the shell.
public struct AppBundleAdminMove: Sendable, Equatable {
    public static let openCleanBundleID = "io.github.leoanimesh.OpenClean"
    public static let moveExecutable = "/bin/mv"
    public static let chownExecutable = "/usr/sbin/chown"

    public let source: String
    public let destination: String
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
    public init(
        source: String, destination: String, bundleID: String, applicationFolders: [String],
        sessionItemsDirectory: String, protectedPaths: [String] = []
    ) throws {
        let uid = getuid()
        guard uid != 0 else { throw AppBundleAdminMoveError.rootUser }
        try Self.validateSource(
            source, bundleID: bundleID, applicationFolders: applicationFolders, protectedPaths: protectedPaths)
        try Self.validateDestination(destination, source: source, sessionItemsDirectory: sessionItemsDirectory)
        self.source = source
        self.destination = destination
        self.uid = uid
        self.gid = getgid()
    }

    /// Each step is one argv (executable first); they run in order and stop at the first failure.
    public var steps: [[String]] {
        [
            [Self.moveExecutable, "-n", "--", source, destination],
            // BSD chown stops option parsing at the owner operand, so `--` must come before it.
            [Self.chownExecutable, "-R", "--", "\(uid):\(gid)", destination],
        ]
    }

    /// Shell text for `do shell script`: every word single-quoted, steps joined with `&&`.
    public var shellText: String {
        steps.map { $0.map(AdminCommandBuilder.shellQuote).joined(separator: " ") }.joined(separator: " && ")
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

/// Runs the Uninstaller's one root command. Accepts nothing but `AppBundleAdminMove`.
public protocol AppBundleAdminExecutor: Sendable {
    func runAsAdmin(_ move: AppBundleAdminMove) -> AdminRunOutcome
}

extension OsascriptAdminExecutor: AppBundleAdminExecutor {
    /// One standard administrator prompt per call; no timeout (a human types the password).
    public func runAsAdmin(_ move: AppBundleAdminMove) -> AdminRunOutcome {
        runPrompted(move.shellText)
    }
}
