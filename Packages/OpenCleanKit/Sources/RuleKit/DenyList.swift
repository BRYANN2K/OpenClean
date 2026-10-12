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
        let path = normalizedPath(rawPath)

        for location in exact where path == location {
            return "protected location \(location)"
        }
        for root in subtrees where isAncestorOrEqual(root, of: path) {
            if allowedInside.contains(where: { isAncestorOrEqual($0, of: path) }) { continue }
            return "inside protected location \(root)"
        }
        for parent in bundleParents where path.hasPrefix(parent + "/") {
            let first = path.dropFirst(parent.count + 1).split(separator: "/").first ?? ""
            if first.hasSuffix(".app") { return "application bundle \(parent)/\(first)" }
        }
        if path.hasPrefix(photosParent + "/") {
            let first = path.dropFirst(photosParent.count + 1).split(separator: "/").first ?? ""
            if first.hasSuffix(".photoslibrary") { return "Photos library \(photosParent)/\(first)" }
        }
        let containedRoots = subtrees + exact.filter { $0 != "/" } + bundleParents + [photosParent]
        for root in containedRoots where path != "/" && isAncestorOrEqual(path, of: root) {
            if allowedInside.contains(where: { isAncestorOrEqual($0, of: path) }) { continue }
            return "contains protected location \(root)"
        }
        return nil
    }
}
