import Foundation

/// Locations OpenClean must never remove, regardless of what a rule pack says.
/// A path is denied if it is a protected location, is inside one, or contains one.
public struct DenyList: Sendable {
    public let home: String
    private let subtrees: [String]
    private let exact: [String]
    private let allowedInside: [String]
    private let bundleParents: [String]
    private let photosParent: String

    public init(home: String) {
        let h = normalizedPath(home)
        self.home = h
        subtrees = [
            "/System", "/bin", "/sbin", "/usr",
            "\(h)/Documents", "\(h)/Desktop",
            "\(h)/Library/Keychains", "/Library/Keychains",
            "\(h)/Library/Mail", "\(h)/Library/Mobile Documents",
        ]
        exact = ["/", h, "/usr/local"]
        allowedInside = ["/usr/local"]
        bundleParents = ["/Applications", "\(h)/Applications"]
        photosParent = "\(h)/Pictures"
    }

    public func isDenied(_ path: String) -> Bool { denialReason(for: path) != nil }

    public func denialReason(for rawPath: String) -> String? {
        // Fail closed: a path we cannot reason about lexically is never deletable.
        guard rawPath.utf8.first == 0x2F else { return "non-canonical path (not absolute)" }
        if hasNonCanonicalComponent(rawPath) {
            return "non-canonical path (contains . or .. component)"
        }
        let path = normalizedPath(rawPath)
        // The filesystem is case-insensitive, so compare lowercased forms.
        let lower = path.lowercased()
        func within(_ root: String) -> Bool { isAncestorOrEqual(root.lowercased(), of: lower) }

        for location in exact where lower == location.lowercased() {
            return "protected location \(location)"
        }
        for root in subtrees where within(root) {
            if allowedInside.contains(where: within) { continue }
            return "inside protected location \(root)"
        }
        let components = path.split(separator: "/").map(String.init)
        for parent in bundleParents where lower.hasPrefix(parent.lowercased() + "/") {
            let depth = parent.split(separator: "/").count
            let below = components.dropFirst(depth)
            if let idx = below.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) {
                let bundle = components.prefix(depth + (idx - below.startIndex) + 1).joined(separator: "/")
                return "application bundle /\(bundle)"
            }
        }
        if lower.hasPrefix(photosParent.lowercased() + "/") {
            let first = path.dropFirst(photosParent.count + 1).split(separator: "/").first ?? ""
            if first.lowercased().hasSuffix(".photoslibrary") { return "Photos library \(photosParent)/\(first)" }
        }
        let containedRoots = subtrees + exact.filter { $0 != "/" } + bundleParents + [photosParent]
        for root in containedRoots where path != "/" && isAncestorOrEqual(lower, of: root.lowercased()) {
            if allowedInside.contains(where: within) { continue }
            return "contains protected location \(root)"
        }
        return nil
    }
}
