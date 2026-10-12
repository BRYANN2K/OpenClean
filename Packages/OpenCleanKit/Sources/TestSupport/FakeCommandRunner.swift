import Foundation
import ProcessKit

/// Returns canned output keyed by "executable arg1 arg2"; unstubbed commands exit 127.
public final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: CommandOutput] = [:]
    private var recorded: [[String]] = []

    public init() {}

    public var calls: [[String]] { lock.withLock { recorded } }

    public func respond(_ commandLine: String, status: Int32 = 0, stdout: String = "", stderr: String = "") {
        lock.withLock {
            responses[commandLine] = CommandOutput(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
        }
    }

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        let line = ([executable] + arguments).joined(separator: " ")
        return lock.withLock {
            recorded.append([executable] + arguments)
            return responses[line] ?? CommandOutput(status: 127, stderr: Data("not stubbed: \(line)".utf8))
        }
    }
}
