import Foundation
import Privilege
import ProcessKit

/// Records admin commands; optionally runs them with /bin/sh as the current (non-root) user.
public final class FakeAdminExecutor: AdminExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    let outcome: AdminRunOutcome
    let runForReal: Bool

    public init(outcome: AdminRunOutcome = .succeeded, runForReal: Bool = false) {
        self.outcome = outcome
        self.runForReal = runForReal
    }

    public var commands: [String] { lock.withLock { recorded } }

    public func runAsAdmin(_ command: RemovalCommand) -> AdminRunOutcome {
        lock.withLock { recorded.append(command.text) }
        if runForReal && outcome == .succeeded {
            _ = try? ProcessCommandRunner().run("/bin/sh", ["-c", command.text])
        }
        return outcome
    }
}
