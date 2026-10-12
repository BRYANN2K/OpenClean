import Foundation

/// A path (or, when report-only, a virtual identifier) found by a probe.
public struct ProbeFinding: Sendable, Equatable {
    public let path: String
    public let reportOnly: Bool
    public let hint: String?

    public init(path: String, reportOnly: Bool = false, hint: String? = nil) {
        self.path = path
        self.reportOnly = reportOnly
        self.hint = hint
    }
}

/// Swift logic for targets a glob cannot express. Probes only find; they never remove.
public protocol Probe: Sendable {
    static var id: String { get }
    func scan(_ context: ScanContext) async throws -> [ProbeFinding]
}

public struct ProbeRegistry: Sendable {
    private let probes: [String: any Probe]

    public init(_ probes: [any Probe]) {
        self.probes = Dictionary(probes.map { (type(of: $0).id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public var ids: Set<String> { Set(probes.keys) }

    public func probe(for id: String) -> (any Probe)? { probes[id] }
}
