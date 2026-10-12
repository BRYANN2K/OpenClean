import Foundation

public enum AdminCommandError: Error, Equatable {
    case noPaths
    case invalidPath(String)
    case tooLong
}

/// A validated root removal command. Only `AdminCommandBuilder` can construct one.
public struct RemovalCommand: Sendable, Equatable {
    public let text: String
    fileprivate init(text: String) { self.text = text }
}

/// Builds the single root command used to delete already-validated, root-owned paths.
/// Paths are passed as individually single-quoted arguments after `--`; nothing is globbed.
public enum AdminCommandBuilder {
    /// Stays well below ARG_MAX (1 MiB) once AppleScript escaping is added.
    public static let maxCommandLength = 400_000

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    public static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
        return "\"" + escaped + "\""
    }

    public static func removalCommand(paths: [String]) throws -> RemovalCommand {
        guard !paths.isEmpty else { throw AdminCommandError.noPaths }
        for path in paths {
            let unsafe = path.contains("\n") || path.contains("\r") || path.contains("\0")
            let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            let canonical = !path.hasSuffix("/") && !components.contains { $0.isEmpty || $0 == "." || $0 == ".." }
            guard path.hasPrefix("/"), path != "/", !unsafe, canonical else {
                throw AdminCommandError.invalidPath(path)
            }
        }
        let command = "/bin/rm -rf -- " + paths.map(shellQuote).joined(separator: " ")
        guard command.utf8.count <= maxCommandLength else { throw AdminCommandError.tooLong }
        return RemovalCommand(text: command)
    }

    public static func appleScript(forShellCommand command: String) -> String {
        "do shell script \(appleScriptLiteral(command)) with administrator privileges"
    }
}
