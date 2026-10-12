import Foundation
import Privilege
import ProcessKit

/// Records admin commands; optionally runs them with /bin/sh as the current (non-root) user.
/// Never shows a prompt. Also stands in for the Uninstaller's `AppBundleAdminMove` executor.
public final class FakeAdminExecutor: AdminExecutor, AppBundleAdminExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var recordedMoves: [AppBundleAdminMove] = []
    let outcome: AdminRunOutcome
    let runForReal: Bool
    let beforeBundleMove: (@Sendable (AppBundleAdminMove) -> Void)?

    /// `beforeBundleMove` runs before a bundle move is (optionally) executed, e.g. to make a read-only
    /// test folder writable so the non-root shell can stand in for root.
    public init(
        outcome: AdminRunOutcome = .succeeded, runForReal: Bool = false,
        beforeBundleMove: (@Sendable (AppBundleAdminMove) -> Void)? = nil
    ) {
        self.outcome = outcome
        self.runForReal = runForReal
        self.beforeBundleMove = beforeBundleMove
    }

    public var commands: [String] { lock.withLock { recorded } }
    public var bundleMoves: [AppBundleAdminMove] { lock.withLock { recordedMoves } }

    public func runAsAdmin(_ command: RemovalCommand) -> AdminRunOutcome {
        lock.withLock { recorded.append(command.text) }
        if runForReal && outcome == .succeeded {
            _ = try? ProcessCommandRunner().run("/bin/sh", ["-c", command.text])
        }
        return outcome
    }

    public func runAsAdmin(_ move: AppBundleAdminMove) -> AdminRunOutcome {
        lock.withLock {
            recorded.append(move.shellText)
            recordedMoves.append(move)
        }
        beforeBundleMove?(move)
        if runForReal && outcome == .succeeded {
            guard let output = try? ProcessCommandRunner().run("/bin/sh", ["-c", move.shellText]) else {
                return .failed("could not run /bin/sh")
            }
            return output.status == 0 ? .succeeded : .failed(output.stderrText)
        }
        return outcome
    }
}
