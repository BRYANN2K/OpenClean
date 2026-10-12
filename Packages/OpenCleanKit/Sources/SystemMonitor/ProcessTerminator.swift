import Darwin
import Foundation

/// Force quits a background process the user picked. Before sending SIGKILL it re-reads the pid's
/// executable path and owner, so a pid reused by another program since sampling is never killed.
public struct ProcessTerminator: Sendable {
    public enum Outcome: Equatable, Sendable {
        case killed
        /// The pid now belongs to a different program, another user, or no longer exists.
        case changed
        case protected
        case failed(errno: Int32)
    }

    let policy: ForceQuitPolicy

    public init(policy: ForceQuitPolicy = ForceQuitPolicy()) {
        self.policy = policy
    }

    public func forceQuit(_ process: ProcessUsage) -> Outcome {
        guard !policy.isProtected(process), let expectedPath = process.path else { return .protected }
        guard let current = Self.identity(of: process.pid),
            current.path == expectedPath, current.uid == process.uid, current.uid == policy.currentUID
        else { return .changed }
        if kill(process.pid, SIGKILL) == 0 { return .killed }
        return errno == ESRCH ? .changed : .failed(errno: errno)
    }

    /// The executable path and owner of a live pid, or nil when it no longer exists.
    static func identity(of pid: Int32) -> (path: String, uid: UInt32)? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(
            decoding: buffer.prefix(Int(length)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return (path, info.pbsi_uid)
    }
}
