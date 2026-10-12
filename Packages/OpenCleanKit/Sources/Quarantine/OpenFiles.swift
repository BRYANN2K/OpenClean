import Foundation
import ProcessKit

public protocol OpenFilesProvider: Sendable {
    /// Absolute paths currently open by processes this user can inspect.
    func openPaths() throws -> Set<String>
}

public enum LsofError: Error, Equatable {
    case noOutput(status: Int32)
}

/// One `lsof` call per cleanup session, in machine-readable field mode.
public struct LsofOpenFilesProvider: OpenFilesProvider {
    let runner: any CommandRunner

    public init(runner: any CommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func openPaths() throws -> Set<String> {
        let output = try runner.run("/usr/sbin/lsof", ["-n", "-P", "-w", "-F", "n"])
        // lsof exits 1 when some processes could not be inspected; output is still usable.
        guard !output.stdout.isEmpty else { throw LsofError.noOutput(status: output.status) }
        return LsofParser.paths(from: output.stdoutText)
    }
}

public enum LsofParser {
    public static func paths(from text: String) -> Set<String> {
        var paths = Set<String>()
        for line in text.split(separator: "\n") where line.hasPrefix("n/") {
            paths.insert(String(line.dropFirst()))
        }
        return paths
    }
}
