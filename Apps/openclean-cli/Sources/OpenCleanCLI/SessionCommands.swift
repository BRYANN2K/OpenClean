import ArgumentParser
import Foundation
import OpenCleanKit
import Quarantine
import RuleKit

struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "history", abstract: "List past cleanup sessions.")

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        let coordinator = CLI.coordinator()
        _ = CLI.bootstrap(coordinator)
        let listings = coordinator.history()
        print(json ? try JSONReport.history(listings) : TextReport.history(listings))
    }
}

struct RestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore", abstract: "Put quarantined items back where they came from.")

    @Argument(help: "Session id from `openclean history`.")
    var sessionID: String

    @Option(name: .customLong("item"), help: "Only restore these original paths (repeatable).")
    var items: [String] = []

    @Option(name: .customLong("on-conflict"), help: "skip, keep-both or replace when the original path is taken.")
    var onConflict: ConflictPolicy = .skip

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        let coordinator = CLI.coordinator()
        _ = CLI.bootstrap(coordinator)
        let expander = PathExpander(home: coordinator.home)
        let selected = items.isEmpty ? nil : Set(items.map(expander.expand))
        let report = try coordinator.restore(sessionID: sessionID, paths: selected, onConflict: onConflict)
        print(json ? try JSONReport.restore(report) : TextReport.restore(report))
        if !report.skipped.isEmpty { throw ExitCode(2) }
    }
}

struct ScheduleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schedule", abstract: "Manage background tasks.", subcommands: [Purge.self])

    struct Purge: ParsableCommand {
        enum Mode: String, EnumerableFlag {
            case daily, off
        }

        static let configuration = CommandConfiguration(
            commandName: "purge", abstract: "Purge expired quarantine sessions daily (LaunchAgent).")

        @Flag(exclusivity: .exclusive)
        var mode: Mode

        func run() throws {
            let schedule = CLI.coordinator().purgeSchedule()
            switch mode {
            case .daily:
                let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
                try schedule.enable(executable: executable)
                print("Daily purge enabled (\(schedule.plistURL.path)).")
            case .off:
                try schedule.disable()
                print("Daily purge disabled.")
            }
        }
    }
}

/// Run by the LaunchAgent. Hidden from help.
struct PurgeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "purge", abstract: "Remove expired quarantine sessions.", shouldDisplay: false)

    func run() throws {
        let coordinator = CLI.coordinator()
        let settings = coordinator.settingsStore.load()
        let purged = coordinator.purgeExpired(settings: settings)
        print("Purged \(purged.count) session(s).")
    }
}
