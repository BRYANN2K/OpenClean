import Foundation
import ProcessKit

public protocol OpenFilesProvider: Sendable {
    /// Absolute paths currently open by processes this user can inspect.
    func openPaths() throws -> Set<String>
}

public enum LsofError: Error, Equatable {
    case noOutput(status: Int32)
    case unexpectedStatus(Int32)
    case unreadablePath
}

/// One `lsof` call per cleanup session, in machine-readable NUL-separated field mode.
public struct LsofOpenFilesProvider: OpenFilesProvider {
    let runner: any CommandRunner

    public init(runner: any CommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func openPaths() throws -> Set<String> {
        let output = try runner.run("/usr/sbin/lsof", ["-n", "-P", "-w", "-F0n"])
        // lsof exits 1 when some processes could not be inspected; output is still usable.
        guard output.status == 0 || output.status == 1 else { throw LsofError.unexpectedStatus(output.status) }
        guard !output.stdout.isEmpty else { throw LsofError.noOutput(status: output.status) }
        return try LsofParser.paths(from: output.stdout)
    }
}

public enum LsofParser {
    /// Parses `lsof -F0n` output. Throws `unreadablePath` if any path field is not valid UTF-8,
    /// because dropping it would hide an open file.
    public static func paths(from data: Data) throws -> Set<String> {
        var paths = Set<String>()
        for var field in data.split(separator: 0x00, omittingEmptySubsequences: true) {
            if field.first == 0x0A { field = field.dropFirst() }
            guard field.first == UInt8(ascii: "n"), field.dropFirst().first == UInt8(ascii: "/") else { continue }
            guard let path = String(bytes: field.dropFirst(), encoding: .utf8) else {
                throw LsofError.unreadablePath
            }
            paths.insert(path)
        }
        return paths
    }
}
