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

    @Test func timesOutWedgedCommand() {
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            do {
                _ = try ProcessCommandRunner(timeout: 0.5).run("/bin/sleep", ["5"])
                Issue.record("expected timeout")
            } catch let error as CommandError {
                if case .timedOut = error {} else { Issue.record("wrong error \(error)") }
            } catch {
                Issue.record("wrong error \(error)")
            }
        }
        #expect(elapsed < .seconds(3))
    }

    @Test func runsWithoutTimeout() throws {
        let output = try ProcessCommandRunner(timeout: nil).run("/bin/echo", ["hi"])
        #expect(output.stdoutText == "hi\n")
    }
}
