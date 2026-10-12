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

    @Test func survivesConcurrentRuns() async {
        let clock = ContinuousClock()
        let start = clock.now
        let outputs = await withTaskGroup(of: CommandOutput?.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    try? ProcessCommandRunner(timeout: 10).run("/bin/sh", ["-c", "echo out; echo err >&2"])
                }
            }
            var results: [CommandOutput?] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(outputs.count == 64)
        for output in outputs {
            #expect(output?.status == 0)
            #expect(output?.stdoutText == "out\n")
            #expect(output?.stderrText == "err\n")
        }
        #expect(clock.now - start < .seconds(20))
    }

    @Test func survivesConcurrentTimeouts() async {
        let clock = ContinuousClock()
        let start = clock.now
        let timedOut = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    do {
                        _ = try ProcessCommandRunner(timeout: 0.5).run("/bin/sleep", ["5"])
                        return false
                    } catch CommandError.timedOut {
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await result in group where result { count += 1 }
            return count
        }
        #expect(timedOut == 64)
        #expect(clock.now - start < .seconds(20))
    }
}
