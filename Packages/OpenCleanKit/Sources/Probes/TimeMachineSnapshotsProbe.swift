import Foundation
import ProcessKit
import ScanEngine

/// Lists local Time Machine snapshots. Report-only in this release.
public struct TimeMachineSnapshotsProbe: Probe {
    public static let id = "timemachine.local-snapshots"
    let runner: any CommandRunner

    public init(runner: any CommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func scan(_ context: ScanContext) async throws -> [ProbeFinding] {
        let output: CommandOutput
        do {
            output = try runner.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        } catch {
            return []
        }
        guard output.status == 0 else { return [] }
        return output.stdoutText.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.TimeMachine.") }
            .map {
                ProbeFinding(
                    path: "tmsnapshot://\($0)", reportOnly: true,
                    hint:
                        "Local Time Machine snapshot. macOS removes these when space is needed; manage with `tmutil deletelocalsnapshots`."
                )
            }
    }
}
