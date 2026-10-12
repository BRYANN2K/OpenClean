import Foundation

/// Expands a leading `~` to an injected home directory (never the process's real home).
public struct PathExpander: Sendable, Equatable {
    public let home: String

    public init(home: String) {
        self.home = normalizedPath(home)
    }

    public func expand(_ pattern: String) -> String {
        if pattern == "~" { return home }
        if pattern.hasPrefix("~/") { return home + pattern.dropFirst(1) }
        return pattern
    }
}
