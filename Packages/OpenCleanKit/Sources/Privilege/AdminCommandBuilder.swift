import Foundation

public enum AdminCommandError: Error, Equatable {
    case noPaths
    case invalidPath(String)
    case tooLong
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

    public static func removalCommand(paths: [String]) throws -> String {
        guard !paths.isEmpty else { throw AdminCommandError.noPaths }
        for path in paths {
            let unsafe = path.contains("\n") || path.contains("\r") || path.contains("\0")
            guard path.hasPrefix("/"), path != "/", !unsafe else {
                throw AdminCommandError.invalidPath(path)
            }
        }
        let command = "/bin/rm -rf -- " + paths.map(shellQuote).joined(separator: " ")
        guard command.utf8.count <= maxCommandLength else { throw AdminCommandError.tooLong }
        return command
    }

    public static func appleScript(forShellCommand command: String) -> String {
        "do shell script \(appleScriptLiteral(command)) with administrator privileges"
    }
}
