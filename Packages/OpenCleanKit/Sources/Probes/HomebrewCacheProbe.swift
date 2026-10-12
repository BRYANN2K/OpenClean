import Foundation
import ProcessKit
import ScanEngine

/// Entries in Homebrew's download cache (`brew --cache`).
public struct HomebrewCacheProbe: Probe {
    public static let id = "homebrew.cache"
    let runner: any CommandRunner
    let brewCandidates: [String]

    public init(
        runner: any CommandRunner = ProcessCommandRunner(),
        brewCandidates: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    ) {
        self.runner = runner
        self.brewCandidates = brewCandidates
    }

    public func scan(_ context: ScanContext) async throws -> [ProbeFinding] {
        guard let brew = brewCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return []
        }
        let output: CommandOutput
        do {
            output = try runner.run(brew, ["--cache"])
        } catch {
            return []
        }
        let cache = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.status == 0, cache.hasPrefix("/") else { return [] }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: cache)) ?? []
        return children.sorted().map { ProbeFinding(path: cache + "/" + $0) }
    }
}
