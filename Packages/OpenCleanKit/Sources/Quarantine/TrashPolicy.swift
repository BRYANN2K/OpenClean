import Foundation
import RuleKit

/// Decides whether a path the *user* picked by hand (Space Lens) may be moved to the Trash.
///
/// Stricter than `DenyList` everywhere except one place: a single regular file strictly inside
/// `~/Documents` or `~/Desktop` may be moved when the user ticks that file explicitly. Every other
/// `DenyList` entry still refuses. The cleanup pipeline keeps using `DenyList` unchanged.
/// All comparisons are canonical and byte-level. `home` must be the resolved (realpath'd) home.
public struct TrashPolicy: Sendable {
    public enum Verdict: Sendable, Equatable {
        /// May be moved to the Trash.
        case allowed
        /// A file inside Documents or Desktop: allowed only as an explicit per-file user action.
        case allowedUserContent
        case refused(String)

        public var isAllowed: Bool { refusal == nil }

        public var refusal: String? {
            if case .refused(let reason) = self { return reason }
            return nil
        }
    }

    /// Bundles and packages whose insides are never touched. `.app` bundles are refused whole.
    public static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "appex", "xpc", "photoslibrary", "musiclibrary",
        "tvlibrary", "imovielibrary", "fcpbundle", "aplibrary", "xcarchive", "logicx", "sparsebundle", "pvm",
        "utm", "vmwarevm",
    ]

    public let home: String
    let denyList: DenyList
    private let criticalSubtrees: [[UInt8]]
    private let criticalExact: [[UInt8]]
    /// Scratch areas inside `/private` that hold the user's own files.
    private let privateScratch: [[UInt8]]
    private let userContentRoots: [[UInt8]]

    public init(home: String) {
        self.home = home
        denyList = DenyList(home: home)
        criticalSubtrees = [
            "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/opt", "/cores", "/dev", "/etc", "/var",
            "/tmp",
            home + "/Library", home + "/Applications",
        ].map(canonicalPathKey)
        criticalExact = ["/", "/Users", "/Volumes"].map(canonicalPathKey)
        privateScratch = ["/private/tmp", "/private/var/folders"].map(canonicalPathKey)
        userContentRoots = [home + "/Documents", home + "/Desktop"].map(canonicalPathKey)
    }

    public func verdict(for path: String, isDirectory: Bool) -> Verdict {
        guard path.utf8.first == 0x2F else { return .refused("not an absolute path") }
        if hasNonCanonicalComponent(path) { return .refused("non-canonical path") }
        let key = canonicalPathKey(path)
        if criticalExact.contains(key) { return .refused("system location") }
        if criticalSubtrees.contains(where: { Self.isWithin(key, $0) }) {
            return .refused("system or library location")
        }
        // `/private` is system territory except the per-user scratch areas (`/tmp`, `$TMPDIR`).
        if Self.isWithin(key, canonicalPathKey("/private"))
            && !privateScratch.contains(where: { Self.isWithin(key, $0) && key != $0 })
        {
            return .refused("system location")
        }

        let components = key.split(separator: 0x2F, omittingEmptySubsequences: true)
        for (index, component) in components.enumerated() {
            if component.elementsEqual(".trash".utf8) || component.elementsEqual(".trashes".utf8) {
                return .refused("already in the Trash")
            }
            if Self.hasExtension(component, "app") { return .refused("application bundle") }
            if index < components.count - 1,
                Self.packageExtensions.contains(where: { Self.hasExtension(component, $0) })
            {
                return .refused("inside a package")
            }
        }

        guard let reason = denyList.denialReason(for: path) else { return .allowed }
        if userContentRoots.contains(where: { Self.isWithin(key, $0) && key != $0 }) {
            return isDirectory
                ? .refused("only individual files can be moved to the Trash from Documents and Desktop")
                : .allowedUserContent
        }
        return .refused(reason)
    }

    /// Verdict for a hypothetical file directly inside `directory`. Walkers use it to decide whether to
    /// descend: `.refused` means never look inside; `.allowedUserContent` means only on user opt-in.
    public func subtreeVerdict(of directory: String) -> Verdict {
        verdict(for: directory + "/openclean-subtree-probe", isDirectory: false)
    }

    /// True when `path` is strictly inside `~/Documents` or `~/Desktop`.
    public func isUserContent(_ path: String) -> Bool {
        let key = canonicalPathKey(path)
        return userContentRoots.contains { Self.isWithin(key, $0) && key != $0 }
    }

    static func isWithin(_ key: [UInt8], _ root: [UInt8]) -> Bool {
        if root == [0x2F] { return true }
        if key.count == root.count { return key == root }
        return key.count > root.count && key.starts(with: root) && key[root.count] == 0x2F
    }

    /// `component` (already case-folded) ends in "." + `ext` and has a non-empty stem.
    static func hasExtension(_ component: ArraySlice<UInt8>, _ ext: String) -> Bool {
        let suffix = Array(".\(ext)".utf8)
        return component.count > suffix.count && component.suffix(suffix.count).elementsEqual(suffix)
    }
}
