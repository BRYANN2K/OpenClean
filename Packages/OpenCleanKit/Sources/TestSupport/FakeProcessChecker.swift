import ScanEngine

public struct FakeProcessChecker: ProcessChecker {
    public let running: Set<String>

    public init(running: Set<String> = []) {
        self.running = running
    }

    public func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
}
