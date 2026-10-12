import Darwin
import Foundation
import ProcessKit
import RuleKit

public enum ScheduleError: Error, Equatable {
    case launchctl(String)
}

/// Optional daily purge via a per-user LaunchAgent. Off by default.
public struct PurgeSchedule: Sendable {
    public static let label = "com.openclean.purge"
    let launchAgents: URL
    let runner: any CommandRunner
    let uid: uid_t

    public init(home: String, runner: any CommandRunner = ProcessCommandRunner(), uid: uid_t = getuid()) {
        launchAgents = URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.runner = runner
        self.uid = uid
    }

    public var plistURL: URL { launchAgents.appendingPathComponent(Self.label + ".plist") }
    public var isEnabled: Bool { FileStat.of(plistURL.path) != nil }

    public func enable(executable: String) throws {
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executable, "purge"],
            "StartCalendarInterval": ["Hour": 3, "Minute": 15],
            "RunAtLoad": false,
        ]
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        _ = try? runner.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(Self.label)"])
        let output: CommandOutput
        do {
            output = try runner.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
        } catch {
            try? FileManager.default.removeItem(at: plistURL)
            throw error
        }
        guard output.status == 0 else {
            try? FileManager.default.removeItem(at: plistURL)
            throw ScheduleError.launchctl(output.stderrText)
        }
    }

    public func disable() throws {
        _ = try? runner.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(Self.label)"])
        if isEnabled { try FileManager.default.removeItem(at: plistURL) }
    }
}
