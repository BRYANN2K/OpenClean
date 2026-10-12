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
        let key = pathKey(path)
        func within(_ root: String) -> Bool { isAncestorOrEqual(pathKey(root), of: key) }
        func hasSuffix(_ component: ArraySlice<UInt8>, _ suffix: String) -> Bool {
            component.count >= suffix.utf8.count && component.suffix(suffix.utf8.count).elementsEqual(suffix.utf8)
        }

        for location in exact where key == pathKey(location) {
            return "protected location \(location)"
        }
        for root in subtrees where within(root) {
            if allowedInside.contains(where: within) { continue }
            return "inside protected location \(root)"
        }
        let components = pathComponents(path)
        let keyComponents = key.split(separator: 0x2F, omittingEmptySubsequences: true)
        for parent in bundleParents where within(parent) && key != pathKey(parent) {
            let depth = pathComponents(parent).count
            let below = keyComponents.dropFirst(depth)
            if let idx = below.firstIndex(where: { hasSuffix($0, ".app") }) {
                let bundle = components.prefix(depth + (idx - below.startIndex) + 1).joined(separator: "/")
                return "application bundle /\(bundle)"
            }
        }
        if within(photosParent), key != pathKey(photosParent) {
            let depth = pathComponents(photosParent).count
            if keyComponents.count > depth, hasSuffix(keyComponents[keyComponents.startIndex + depth], ".photoslibrary") {
                return "Photos library \(photosParent)/\(components[depth])"
            }
        }
        let containedRoots = subtrees + exact.filter { $0 != "/" } + bundleParents + [photosParent]
        for root in containedRoots where path != "/" && isAncestorOrEqual(key, of: pathKey(root)) {
            if allowedInside.contains(where: within) { continue }
            return "contains protected location \(root)"
        }
        return nil
    }
}
