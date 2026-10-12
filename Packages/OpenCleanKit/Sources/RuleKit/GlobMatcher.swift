import Darwin
import Foundation

public struct GlobResult: Sendable, Equatable {
    public var matches: [String]
    public var errors: [String]
}

/// Matches absolute glob patterns component by component.
/// `*`, `?` and `[...]` match within one component (including dot-files); `**` matches zero or
/// more directory levels. Symlinked directories are never traversed; a symlink that matches the
/// final component is returned so the scanner can reject it.
public struct GlobMatcher: Sendable {
    public init() {}

    public static func hasWildcard(_ component: some StringProtocol) -> Bool {
        component.contains { $0 == "*" || $0 == "?" || $0 == "[" }
    }

    public static func literalPrefix(of pattern: String) -> String {
        let components = pattern.split(separator: "/")
        let literal = components.prefix { !hasWildcard($0) }
        return "/" + literal.joined(separator: "/")
    }

    public func match(_ pattern: String) -> GlobResult {
        precondition(pattern.hasPrefix("/"), "glob patterns must be absolute")
        let components = pattern.split(separator: "/").map(String.init)
        let literalCount = components.prefix { !Self.hasWildcard($0) }.count
        let base = "/" + components.prefix(literalCount).joined(separator: "/")
        let rest = components.dropFirst(literalCount)

        var result = GlobResult(matches: [], errors: [])
        if rest.isEmpty {
            if FileStat.of(base) != nil { result.matches = [base] }
            return result
        }
        guard let baseStat = FileStat.of(base), baseStat.isDirectory else { return result }
        var seen = Set<String>()
        walk(directory: base, components: rest, result: &result, seen: &seen)
        return result
    }

    private func walk(
        directory: String, components: ArraySlice<String>,
        result: inout GlobResult, seen: inout Set<String>
    ) {
        guard let component = components.first else { return }
        let remaining = components.dropFirst()

        if component == "**" {
            guard !remaining.isEmpty else { return }
            walk(directory: directory, components: remaining, result: &result, seen: &seen)
            for child in children(of: directory, errors: &result.errors) {
                let childPath = join(directory, child)
                if FileStat.of(childPath)?.isDirectory == true {
                    walk(directory: childPath, components: components, result: &result, seen: &seen)
                }
            }
            return
        }

        for child in children(of: directory, errors: &result.errors) where fnmatch(component, child, 0) == 0 {
            let childPath = join(directory, child)
            if remaining.isEmpty {
                if seen.insert(childPath).inserted { result.matches.append(childPath) }
            } else if FileStat.of(childPath)?.isDirectory == true {
                walk(directory: childPath, components: remaining, result: &result, seen: &seen)
            }
        }
    }

    private func children(of directory: String, errors: inout [String]) -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        } catch {
            errors.append("\(directory): \(error.localizedDescription)")
            return []
        }
    }

    private func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }
}
