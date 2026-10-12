import Foundation
import ProcessKit

/// The complete, closed set of maintenance commands OpenClean may run as root.
///
/// There is deliberately no way to build one from arbitrary strings: cases carry no associated values,
/// every step is a fixed absolute executable with fixed arguments, and executables must be in
/// `allowedExecutables`. Adding a task means adding a case here, reviewed like any other root code path.
public enum MaintenanceAdminCommand: String, CaseIterable, Sendable, Codable {
    case flushDNSCache
    case reindexSpotlight
    case runPeriodicScripts
    case thinLocalSnapshots

    /// Purge amount for `tmutil thinlocalsnapshots`: "as much as macOS is willing to thin".
    public static let thinPurgeBytes = "999999999999"
    /// Highest urgency `tmutil thinlocalsnapshots` accepts.
    public static let thinUrgency = "4"

    public static let allowedExecutables: Set<String> = [
        "/usr/bin/dscacheutil", "/usr/bin/killall", "/usr/bin/mdutil", "/usr/sbin/periodic", "/usr/bin/tmutil",
    ]

    /// Each step is one argv (executable first). Steps run in order and stop at the first failure.
    public var steps: [[String]] {
        switch self {
        case .flushDNSCache:
            [["/usr/bin/dscacheutil", "-flushcache"], ["/usr/bin/killall", "-HUP", "mDNSResponder"]]
        case .reindexSpotlight:
            [["/usr/bin/mdutil", "-E", "/"]]
        case .runPeriodicScripts:
            [["/usr/sbin/periodic", "daily", "weekly", "monthly"]]
        case .thinLocalSnapshots:
            [["/usr/bin/tmutil", "thinlocalsnapshots", "/", Self.thinPurgeBytes, Self.thinUrgency]]
        }
    }

    /// The executables this command needs; used to hide tasks whose tools don't exist on this macOS.
    public var executables: [String] { steps.compactMap(\.first) }

    /// Shell text for `do shell script`: every word single-quoted, steps joined with `&&`.
    /// Throws if a step ever names an executable outside the allow-list (defence in depth).
    public func shellText() throws -> String {
        try steps.map { argv in
            guard let executable = argv.first, Self.allowedExecutables.contains(executable),
                executable.utf8.first == 0x2F
            else { throw MaintenanceAdminCommandError.notAllowed(argv.first ?? "") }
            return argv.map(AdminCommandBuilder.shellQuote).joined(separator: " ")
        }
        .joined(separator: " && ")
    }
}

public enum MaintenanceAdminCommandError: Error, Equatable {
    case notAllowed(String)
}

/// Runs one allow-listed maintenance command as root. Accepts nothing but `MaintenanceAdminCommand`.
public protocol MaintenanceAdminExecutor: Sendable {
    func runAsAdmin(_ command: MaintenanceAdminCommand) -> AdminRunOutcome
}

extension OsascriptAdminExecutor: MaintenanceAdminExecutor {
    /// One standard administrator prompt per call; no timeout (a human types the password).
    public func runAsAdmin(_ command: MaintenanceAdminCommand) -> AdminRunOutcome {
        let text: String
        do {
            text = try command.shellText()
        } catch {
            return .failed("\(error)")
        }
        let script = AdminCommandBuilder.appleScript(forShellCommand: text)
        do {
            let output = try runner.run("/usr/bin/osascript", ["-e", script])
            if output.status == 0 { return .succeeded }
            let message = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.hasSuffix("(-128)") { return .cancelled }
            return .failed(message.isEmpty ? "exit status \(output.status)" : message)
        } catch {
            return .failed("\(error)")
        }
    }
}
