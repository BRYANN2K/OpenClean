import ArgumentParser
import Foundation
import OpenCleanKit
import SystemMonitor

/// One CPU/memory reading plus the heaviest processes, measured over `interval` seconds.
public struct PerformanceSnapshot: Sendable {
    public let interval: Double
    public let monitor: MonitorSnapshot
    public let topCPU: [ProcessGroup]
    public let topMemory: [ProcessGroup]

    public init(interval: Double, monitor: MonitorSnapshot, limit: Int) {
        self.interval = interval
        self.monitor = monitor
        let groups = monitor.groups ?? []
        topCPU = ProcessUsageCalculator.topByCPU(groups, limit: limit)
        topMemory = ProcessUsageCalculator.topByMemory(groups, limit: limit)
    }
}

struct PerformanceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "performance",
        abstract: "Show CPU and memory use and the heaviest apps and processes. Read-only.")

    @Option(help: "How many apps and processes to list in each table.")
    var limit = 10

    @Option(help: "Seconds to measure CPU use over (0.2–10).")
    var interval = 1.0

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func validate() throws {
        guard limit > 0 else { throw ValidationError("--limit must be at least 1") }
        guard (0.2...10).contains(interval) else { throw ValidationError("--interval must be between 0.2 and 10") }
    }

    func run() async throws {
        let monitor = CLI.coordinator().makeSystemMonitor()
        let request: SampleRequest = [.metrics, .processes]
        _ = monitor.next(request)
        try await Task.sleep(for: .seconds(interval))
        let snapshot = PerformanceSnapshot(interval: interval, monitor: monitor.next(request), limit: limit)
        print(json ? try JSONReport.performance(snapshot) : TextReport.performance(snapshot))
    }
}
