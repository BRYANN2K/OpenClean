import Foundation
import Privilege
import ProcessKit

/// One-click macOS maintenance. Every task is a fixed command; admin tasks map 1:1 onto an allow-listed
/// `MaintenanceAdminCommand`. Freeing "purgeable RAM" (`purge`) is deliberately absent: it only makes
/// macOS reload what it had cached.
public enum MaintenanceTask: String, CaseIterable, Sendable, Codable, Identifiable {
    case flushDNSCache
    case reindexSpotlight
    case rebuildLaunchServices
    case runPeriodicScripts
    case thinLocalSnapshots

    public var id: String { rawValue }

    public static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    public var title: String {
        switch self {
        case .flushDNSCache: "Flush DNS cache"
        case .reindexSpotlight: "Reindex Spotlight"
        case .rebuildLaunchServices: "Rebuild Launch Services database"
        case .runPeriodicScripts: "Run maintenance scripts"
        case .thinLocalSnapshots: "Thin Time Machine local snapshots"
        }
    }

    public var explanation: String {
        switch self {
        case .flushDNSCache:
            "Forgets cached website addresses, so name lookups start fresh. Helps when a site moved or won't load after a network change."
        case .reindexSpotlight:
            "Erases and rebuilds the Spotlight index for your startup disk. Use it when search misses files. Rebuilding runs in the background and can take an hour or more."
        case .rebuildLaunchServices:
            "Rebuilds the list that decides which app opens which file and what appears in “Open With”. Fixes duplicate or missing entries. Default apps you chose may need choosing again."
        case .runPeriodicScripts:
            "Runs the daily, weekly and monthly housekeeping scripts macOS ships with (log rotation, temporary file cleanup). macOS normally runs them on its own."
        case .thinLocalSnapshots:
            "Asks macOS to remove the local Time Machine snapshots it can drop to free space. Backups on your backup disk are not touched."
        }
    }

    public var needsAdmin: Bool { adminCommand != nil }

    /// The root command this task runs, if it needs administrator rights.
    public var adminCommand: MaintenanceAdminCommand? {
        switch self {
        case .flushDNSCache: .flushDNSCache
        case .reindexSpotlight: .reindexSpotlight
        case .rebuildLaunchServices: nil
        case .runPeriodicScripts: .runPeriodicScripts
        case .thinLocalSnapshots: .thinLocalSnapshots
        }
    }

    /// The argv for tasks that run as you.
    public var userCommand: [String]? {
        switch self {
        case .rebuildLaunchServices:
            [Self.lsregister, "-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"]
        default: nil
        }
    }

    /// Executables that must exist for the task to be offered.
    public var executables: [String] { adminCommand?.executables ?? userCommand.map { [$0[0]] } ?? [] }

    /// Tasks whose tools exist on this Mac (e.g. `periodic` was removed in macOS 26).
    public static func available(fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })
        -> [MaintenanceTask]
    {
        allCases.filter { $0.executables.allSatisfy(fileExists) }
    }
}

public enum MaintenanceOutcome: Sendable, Equatable {
    case succeeded
    case cancelled
    case failed(String)
}

/// Runs maintenance tasks. Success is only reported when the command's exit status was 0.
public struct MaintenanceRunner: Sendable {
    let runner: any CommandRunner
    let admin: any MaintenanceAdminExecutor

    /// Launch Services rebuilds can take minutes, hence the long timeout for user tasks.
    public init(
        runner: any CommandRunner = ProcessCommandRunner(timeout: 300),
        admin: any MaintenanceAdminExecutor = OsascriptAdminExecutor()
    ) {
        self.runner = runner
        self.admin = admin
    }

    public func run(_ task: MaintenanceTask) -> MaintenanceOutcome {
        if let command = task.adminCommand {
            switch admin.runAsAdmin(command) {
            case .succeeded: return .succeeded
            case .cancelled: return .cancelled
            case .failed(let message): return .failed(message)
            }
        }
        guard let argv = task.userCommand, let executable = argv.first else {
            return .failed("no command for \(task.rawValue)")
        }
        do {
            let output = try runner.run(executable, Array(argv.dropFirst()))
            if output.status == 0 { return .succeeded }
            let message = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(message.isEmpty ? "exit status \(output.status)" : message)
        } catch {
            return .failed("\(error)")
        }
    }
}

/// When each task last ran and whether it worked; `<support>/maintenance.json`.
public struct MaintenanceRecord: Codable, Sendable, Equatable {
    public var date: Date
    public var succeeded: Bool

    public init(date: Date, succeeded: Bool) {
        self.date = date
        self.succeeded = succeeded
    }
}

public struct MaintenanceHistoryStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Unknown task names in the file are ignored; a damaged file reads as empty.
    public func load() -> [MaintenanceTask: MaintenanceRecord] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let raw = try? decoder.decode([String: MaintenanceRecord].self, from: data) else { return [:] }
        var records: [MaintenanceTask: MaintenanceRecord] = [:]
        for (key, value) in raw {
            if let task = MaintenanceTask(rawValue: key) { records[task] = value }
        }
        return records
    }

    public func record(_ task: MaintenanceTask, outcome: MaintenanceOutcome, at date: Date = .now) throws {
        guard outcome != .cancelled else { return }
        var records = load()
        records[task] = MaintenanceRecord(date: date.wholeSecondsDate, succeeded: outcome == .succeeded)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let raw = Dictionary(uniqueKeysWithValues: records.map { ($0.key.rawValue, $0.value) })
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(raw).write(to: url, options: .atomic)
    }
}

extension Date {
    fileprivate var wholeSecondsDate: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
