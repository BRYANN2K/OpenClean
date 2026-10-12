import Foundation
import Privilege

/// Records maintenance admin commands and returns a canned outcome. Never prompts, never runs anything.
public final class FakeMaintenanceAdminExecutor: MaintenanceAdminExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [MaintenanceAdminCommand] = []
    let outcome: AdminRunOutcome

    public init(outcome: AdminRunOutcome = .succeeded) {
        self.outcome = outcome
    }

    public var commands: [MaintenanceAdminCommand] { lock.withLock { recorded } }

    public func runAsAdmin(_ command: MaintenanceAdminCommand) -> AdminRunOutcome {
        lock.withLock { recorded.append(command) }
        return outcome
    }
}
