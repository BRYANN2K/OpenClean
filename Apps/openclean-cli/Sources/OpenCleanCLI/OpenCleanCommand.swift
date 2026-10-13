import ArgumentParser
import Foundation

/// Root command. Plain `ParsableCommand`: `execute(arguments:)` dispatches async subcommands itself.
public struct OpenCleanCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "openclean",
        abstract: "Transparent, open-source cleanup for macOS.",
        version: openCleanVersion,
        subcommands: [
            ScanCommand.self, CleanCommand.self, HistoryCommand.self, RestoreCommand.self, AppsCommand.self,
            SpaceCommand.self, PerformanceCommand.self,
            RulesCommand.self, ScheduleCommand.self, PurgeCommand.self,
        ]
    )

    public init() {}

    /// Runs the CLI and returns the process exit code:
    /// 0 success (and --help/--version), 1 error or aborted, 2 completed with skipped items.
    public static func execute(arguments: [String]) async -> Int32 {
        do {
            var command = try parseAsRoot(arguments)
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            return 0
        } catch let code as ExitCode {
            return code.rawValue
        } catch {
            if exitCode(for: error) == .success {
                print(fullMessage(for: error))
                return 0
            }
            CLI.printError(fullMessage(for: error))
            return 1
        }
    }
}
