import Foundation
import ProcessKit

public enum AdminRunOutcome: Sendable, Equatable {
    case succeeded
    case cancelled
    case failed(String)
}

public protocol AdminExecutor: Sendable {
    func runAsAdmin(shellCommand: String) -> AdminRunOutcome
}

/// Shows the standard macOS administrator prompt via `osascript`. One call = one prompt.
public struct OsascriptAdminExecutor: AdminExecutor {
    let runner: any CommandRunner

    /// No timeout by default: the prompt waits for a human to type a password.
    public init(runner: any CommandRunner = ProcessCommandRunner(timeout: nil)) {
        self.runner = runner
    }

    public func runAsAdmin(shellCommand: String) -> AdminRunOutcome {
        let script = AdminCommandBuilder.appleScript(forShellCommand: shellCommand)
        do {
            let output = try runner.run("/usr/bin/osascript", ["-e", script])
            if output.status == 0 { return .succeeded }
            if output.stderrText.contains("-128") { return .cancelled }
            return .failed(output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failed("\(error)")
        }
    }
}
