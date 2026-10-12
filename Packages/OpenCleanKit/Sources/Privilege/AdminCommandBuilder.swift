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
        let escaped =
            value
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
        return "\"" + escaped + "\""
    }

    public static func removalCommand(paths: [String]) throws -> RemovalCommand {
        guard !paths.isEmpty else { throw AdminCommandError.noPaths }
        for path in paths where !isCanonicalAbsolute(path) {
            throw AdminCommandError.invalidPath(path)
        }
        let command = "/bin/rm -rf -- " + paths.map(shellQuote).joined(separator: " ")
        guard command.utf8.count <= maxCommandLength else { throw AdminCommandError.tooLong }
        return RemovalCommand(text: command)
    }

    /// Byte-based on purpose: String/Character views merge "/" with a following combining mark,
    /// which would hide separators and let "." / ".." components through.
    private static func isCanonicalAbsolute(_ path: String) -> Bool {
        let bytes = path.utf8
        guard bytes.first == 0x2F, bytes.count > 1, bytes.last != 0x2F else { return false }
        if bytes.contains(where: { $0 == 0x00 || $0 == 0x0A || $0 == 0x0D }) { return false }
        for component in bytes.split(separator: 0x2F, omittingEmptySubsequences: false).dropFirst() {
            if component.isEmpty || component.elementsEqual([0x2E]) || component.elementsEqual([0x2E, 0x2E]) {
                return false
            }
        }
        return true
    }

    public static func appleScript(forShellCommand command: String) -> String {
        "do shell script \(appleScriptLiteral(command)) with administrator privileges"
    }
}
