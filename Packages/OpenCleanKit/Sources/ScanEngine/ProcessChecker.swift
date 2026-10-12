import Darwin
import Foundation

public protocol ProcessChecker: Sendable {
    func isRunning(bundleID: String) -> Bool
}

/// Finds running apps by walking the process table and reading each process's enclosing
/// `.app` bundle identifier. Pure Darwin + Foundation, safe off the main thread.
public struct RunningProcessChecker: ProcessChecker {
    public init() {}

    public func isRunning(bundleID: String) -> Bool {
        Self.runningBundleIDs().contains(bundleID)
    }

    public static func runningBundleIDs() -> Set<String> {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        var bundlePaths = Set<String>()
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            guard let range = path.range(of: ".app/", options: .backwards) else { continue }
            bundlePaths.insert(String(path[..<range.upperBound].dropLast()))
        }
        return Set(bundlePaths.compactMap { Bundle(path: $0)?.bundleIdentifier })
    }
}
