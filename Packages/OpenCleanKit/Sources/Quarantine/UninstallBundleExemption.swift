import Darwin
import Foundation
import RuleKit

/// Why an uninstall request was turned down. Nothing is moved when a request is refused.
public enum UninstallRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidBundleID
    case appleApp
    case openClean
    case missing
    case notCanonical
    case notAnAppBundle
    case outsideApplicationFolders
    case needsAdministrator
    case notWritable
    case protected(String)
    case leftoverOutsideLibrary(String)
    case skipped(SkipReason)

    public var description: String {
        switch self {
        case .invalidBundleID: "the app has no usable bundle identifier"
        case .appleApp: "Apple apps are part of macOS and are never removed"
        case .openClean: "OpenClean can't uninstall itself"
        case .missing: "the app is no longer there"
        case .notCanonical: "the app's path goes through a symbolic link or is not canonical"
        case .notAnAppBundle: "this is not an application bundle"
        case .outsideApplicationFolders: "only apps directly inside an Applications folder can be uninstalled"
        case .needsAdministrator: "needs your administrator password to uninstall"
        case .notWritable: "you don't have permission to move this app"
        case .protected(let reason): "protected (\(reason))"
        case .leftoverOutsideLibrary(let path): "\(path) is not inside your Library folder"
        case .skipped(let reason): reason.description
        }
    }
}

/// Lets exactly one application bundle past the deny-list's "application bundle" rule for one uninstall
/// request. Built only by `authorize`, which checks that the path is a canonical, user-writable,
/// non-Apple, non-OpenClean `.app` directly inside one of the allowed Applications folders.
/// With `administrator: true` (the bundle will be moved by `AppBundleAdminMove` after a password prompt)
/// the "not owned by root" and "writable by you" checks are left out; every other check still applies.
/// Every other deny-list rule, and every other path (including paths inside the bundle), stays denied.
public struct UninstallBundleExemption: Sendable, Equatable {
    public let bundlePath: String
    let key: [UInt8]
    /// The deny-list reason recorded at authorization; nil if the path wasn't denied then.
    let expectedReason: String?

    public static func authorize(
        bundlePath path: String, bundleID: String, allowedFolders: [String], denyList: DenyList,
        protectedBundleIDs: Set<String>, protectedPaths: [String], administrator: Bool = false
    ) -> Result<UninstallBundleExemption, UninstallRefusal> {
        guard !bundleID.isEmpty, !bundleID.utf8.contains(0x2F), !bundleID.utf8.contains(0) else {
            return .failure(.invalidBundleID)
        }
        if bundleID.lowercased().starts(with: "com.apple.") || pathIsWithin(path, "/System", caseInsensitive: true) {
            return .failure(.appleApp)
        }
        if protectedBundleIDs.contains(where: { $0.lowercased() == bundleID.lowercased() }) {
            return .failure(.openClean)
        }
        let key = canonicalPathKey(path)
        for protected in protectedPaths {
            let resolved = realPath(protected) ?? protected
            if pathIsWithin(path, resolved, caseInsensitive: true)
                || pathIsWithin(resolved, path, caseInsensitive: true)
            {
                return .failure(.openClean)
            }
        }

        guard path.utf8.first == 0x2F, !hasNonCanonicalComponent(path) else { return .failure(.notCanonical) }
        guard let stat = FileStat.of(path) else { return .failure(.missing) }
        guard !stat.isSymlink, realPath(path).map({ Array($0.utf8) == Array(path.utf8) }) == true else {
            return .failure(.notCanonical)
        }
        let bytes = Array(path.utf8)
        guard let slash = bytes.lastIndex(of: 0x2F), slash > 0 else { return .failure(.outsideApplicationFolders) }
        let parent = String(decoding: bytes[..<slash], as: UTF8.self)
        let name = String(decoding: bytes[(slash + 1)...], as: UTF8.self)
        let nameKey = canonicalPathKey("/" + name)
        let suffix = Array(".app".utf8)
        guard stat.isDirectory, nameKey.count > suffix.count + 1, nameKey.suffix(suffix.count).elementsEqual(suffix)
        else { return .failure(.notAnAppBundle) }

        let parentKey = canonicalPathKey(parent)
        let allowed = allowedFolders.contains { folder in
            canonicalPathKey(realPath(folder) ?? folder) == parentKey
        }
        guard allowed else { return .failure(.outsideApplicationFolders) }

        if !administrator {
            if stat.ownerUID == 0 { return .failure(.needsAdministrator) }
            guard access(path, W_OK) == 0, access(parent, W_OK) == 0 else { return .failure(.notWritable) }
        }

        let reason = denyList.denialReason(for: path)
        if let reason, reason != "application bundle \(path)" { return .failure(.protected(reason)) }
        return .success(UninstallBundleExemption(bundlePath: path, key: key, expectedReason: reason))
    }

    /// True only for the authorized bundle itself, and only when it is denied for the same reason as at
    /// authorization (the application-bundle rule). Never for anything inside it.
    public func permits(_ path: String, deniedFor reason: String) -> Bool {
        guard let expectedReason else { return false }
        return canonicalPathKey(path) == key && reason == expectedReason
    }
}
