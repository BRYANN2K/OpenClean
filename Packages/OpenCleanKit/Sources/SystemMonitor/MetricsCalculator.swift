import Foundation

/// Memory figures as Activity Monitor shows them.
public struct MemoryUsage: Sendable, Equatable {
    public var used: UInt64
    public var total: UInt64
    public var appMemory: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var pressure: MemoryPressure

    public init(
        used: UInt64, total: UInt64, appMemory: UInt64, wired: UInt64, compressed: UInt64, pressure: MemoryPressure
    ) {
        self.used = used
        self.total = total
        self.appMemory = appMemory
        self.wired = wired
        self.compressed = compressed
        self.pressure = pressure
    }

    public var usedFraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
}

public struct NetworkRates: Sendable, Equatable {
    public var receivedPerSecond: Double
    public var sentPerSecond: Double

    public init(receivedPerSecond: Double, sentPerSecond: Double) {
        self.receivedPerSecond = receivedPerSecond
        self.sentPerSecond = sentPerSecond
    }

    public static let zero = NetworkRates(receivedPerSecond: 0, sentPerSecond: 0)
}

/// Pure delta math over two raw samples. Counters can wrap or reset (interface down/up, sleep);
/// a counter that went backwards contributes zero rather than a huge or negative value.
public enum MetricsCalculator {
    /// Busy fraction 0…1 across all cores between two tick samples; nil when no time elapsed.
    public static func cpuUsage(from previous: CPUTicks, to current: CPUTicks) -> Double? {
        let user = delta(previous.user, current.user)
        let system = delta(previous.system, current.system)
        let nice = delta(previous.nice, current.nice)
        let idle = delta(previous.idle, current.idle)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return nil }
        return min(1, max(0, Double(busy) / Double(total)))
    }

    /// Used = app memory (anonymous minus purgeable) + wired + compressed, like Activity Monitor.
    public static func memoryUsage(_ snapshot: MemorySnapshot) -> MemoryUsage {
        let app = snapshot.internal > snapshot.purgeable ? snapshot.internal - snapshot.purgeable : 0
        let used = min(snapshot.physical, app + snapshot.wired + snapshot.compressed)
        return MemoryUsage(
            used: used, total: snapshot.physical, appMemory: app, wired: snapshot.wired,
            compressed: snapshot.compressed, pressure: snapshot.pressure)
    }

    /// Bytes per second between two counter samples taken `interval` seconds apart.
    public static func networkRates(
        from previous: NetworkCounters, to current: NetworkCounters, interval: TimeInterval
    ) -> NetworkRates {
        guard interval > 0 else { return .zero }
        return NetworkRates(
            receivedPerSecond: Double(delta(previous.received, current.received)) / interval,
            sentPerSecond: Double(delta(previous.sent, current.sent)) / interval)
    }

    /// `current - previous`, or 0 when the counter went backwards (wrap, reset, reboot).
    static func delta(_ previous: UInt64, _ current: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }
}
