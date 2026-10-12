import Foundation

/// One node of the space map: a folder, a file, or an "Other" aggregate of folded small children.
public struct SpaceNode: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable {
        case directory
        case file
        case symlink
        /// Children folded together to bound memory; `foldedCount` says how many.
        case other(foldedCount: Int)
    }

    /// The canonical path for real nodes; parent path + "\u{0}other" for aggregates.
    public let id: String
    public let name: String
    public let kind: Kind
    /// Allocated bytes of this item and everything below it.
    public internal(set) var size: Int64
    /// Filesystem entries below and including this one.
    public internal(set) var itemCount: Int
    /// Largest first. Empty for files, aggregates, and truncated or unreadable folders.
    public internal(set) var children: [SpaceNode]
    /// The folder has contents that were summarized instead of kept (depth limit).
    public let isTruncated: Bool
    /// The folder could not be listed; its size covers only the folder entry itself.
    public let isUnreadable: Bool
    /// nil for aggregates.
    public let snapshot: FileSnapshot?

    public init(
        id: String, name: String, kind: Kind, size: Int64, itemCount: Int, children: [SpaceNode] = [],
        isTruncated: Bool = false, isUnreadable: Bool = false, snapshot: FileSnapshot?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.size = size
        self.itemCount = itemCount
        self.children = children
        self.isTruncated = isTruncated
        self.isUnreadable = isUnreadable
        self.snapshot = snapshot
    }

    public var path: String? { snapshot?.path }
    public var isDirectory: Bool { kind == .directory }
    public var isAggregate: Bool {
        if case .other = kind { return true }
        return false
    }

    /// The node with `id` in this subtree.
    public func node(withID target: String) -> SpaceNode? {
        trail(to: target)?.last
    }

    /// Nodes from this one down to `id`, inclusive; nil when not in this subtree.
    public func trail(to target: String) -> [SpaceNode]? {
        if id == target { return [self] }
        for child in children {
            if let rest = child.trail(to: target) { return [self] + rest }
        }
        return nil
    }

    /// A copy without the nodes in `ids`; their sizes and counts are subtracted from every ancestor.
    public func removing(_ ids: Set<String>) -> SpaceNode {
        removingCounted(ids).node
    }

    private func removingCounted(_ ids: Set<String>) -> (node: SpaceNode, bytes: Int64, items: Int) {
        guard !children.isEmpty else { return (self, 0, 0) }
        var copy = self
        var bytes: Int64 = 0
        var items = 0
        var kept: [SpaceNode] = []
        for child in children {
            if ids.contains(child.id) {
                bytes += child.size
                items += child.itemCount
            } else {
                let (updated, b, i) = child.removingCounted(ids)
                bytes += b
                items += i
                kept.append(updated)
            }
        }
        copy.children = kept.sorted(by: SpaceNode.largestFirst)
        copy.size -= bytes
        copy.itemCount -= items
        return (copy, bytes, items)
    }

    static func largestFirst(_ a: SpaceNode, _ b: SpaceNode) -> Bool {
        if a.isAggregate != b.isAggregate { return !a.isAggregate }
        return a.size != b.size ? a.size > b.size : a.name < b.name
    }
}
