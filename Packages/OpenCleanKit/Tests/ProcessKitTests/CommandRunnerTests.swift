import Foundation
import Testing
@testable import ProcessKit

struct CommandRunnerTests {
    let runner = ProcessCommandRunner()

    @Test func capturesStdoutAndStatus() throws {
        let output = try runner.run("/bin/echo", ["hello", "world"])
        #expect(output.status == 0)
        #expect(output.stdoutText == "hello world\n")
    }

    @Test func capturesStderrAndFailureStatus() throws {
        let output = try runner.run("/bin/sh", ["-c", "echo oops >&2; exit 3"])
        #expect(output.status == 3)
        #expect(output.stderrText == "oops\n")
    }

    @Test func reportsMissingExecutable() {
        #expect(throws: CommandError.self) { try runner.run("/nonexistent/tool", []) }
    }
}
