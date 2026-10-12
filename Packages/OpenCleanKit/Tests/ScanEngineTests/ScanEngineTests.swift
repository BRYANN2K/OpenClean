import Foundation
import RuleKit
import Testing
import TestSupport
@testable import ScanEngine

struct StubProbe: Probe {
    static let id = "stub.probe"
    let findings: [ProbeFinding]
    func scan(_ context: ScanContext) async throws -> [ProbeFinding] { findings }
}

struct SlowProbe: Probe {
    static let id = "slow.probe"
    func scan(_ context: ScanContext) async throws -> [ProbeFinding] {
        try await Task.sleep(for: .seconds(30))
        return []
    }
}

struct ScanEngineTests {
    func context(_ home: TempDirectory) -> ScanContext {
        ScanContext(home: home.path, hasFullDiskAccess: true, processChecker: FakeProcessChecker())
    }

    func pathRule(_ id: String, _ paths: [String]) -> Rule {
        Rule(id: id, name: id, category: .user, explain: "x", paths: paths, safety: .regenerable)
    }

    func probeRule(_ id: String, probe: String) -> Rule {
        Rule(id: id, name: id, category: .developer, explain: "x", probe: probe, safety: .review)
    }

    @Test func returnsResultsInRuleOrderAndReportsProgress() async throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/a/f", bytes: 10)
        try home.file("Library/Logs/b.log", bytes: 10)
        let rules = [
            pathRule("one", ["~/Library/Caches/*"]),
            pathRule("two", ["~/Library/Logs/*"]),
            pathRule("three", ["~/nothing/*"]),
        ]
        let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)
        let result = await ScanEngine().scan(rules, context: context(home), progress: continuation)
        var events: [ScanProgress] = []
        for await event in stream { events.append(event) }

        #expect(result.rules.map(\.rule.id) == ["one", "two", "three"])
        #expect(result.isComplete)
        #expect(events.count == 3)
        #expect(events.last?.finished == 3)
        #expect(events.last?.fraction == 1)
    }

    @Test func overlappingRulesCountEachFileOnce() async throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/Homebrew/bottle.tar", bytes: 8_192)
        try home.file("Library/Caches/other/f", bytes: 10)
        let rules = [
            pathRule("homebrew", ["~/Library/Caches/Homebrew/*"]),
            pathRule("caches", ["~/Library/Caches/*"]),
        ]
        let result = await ScanEngine().scan(rules, context: context(home))
        #expect(result.rule("homebrew")?.items.map(\.path) == [home.path + "/Library/Caches/Homebrew/bottle.tar"])
        #expect(result.rule("caches")?.items.map(\.path) == [home.path + "/Library/Caches/other"])
    }

    @Test func probeFindingsPassTheSameSafetyChecks() async throws {
        let home = try TempDirectory()
        let device = home.path + "/Library/Developer/CoreSimulator/Devices/ABC"
        try home.file("Library/Developer/CoreSimulator/Devices/ABC/data", bytes: 4_096)
        try home.file("Documents/x", bytes: 10)
        let probe = StubProbe(findings: [
            ProbeFinding(path: device, hint: "old"),
            ProbeFinding(path: home.path + "/Documents"),
            ProbeFinding(path: "tmsnapshot://com.apple.TimeMachine.1", reportOnly: true, hint: "snap"),
        ])
        let engine = ScanEngine(registry: ProbeRegistry([probe]))
        let result = await engine.scan([probeRule("sims", probe: StubProbe.id)], context: context(home))
        let items = try #require(result.rule("sims")).items
        #expect(Set(items.map(\.path)) == [device, "tmsnapshot://com.apple.TimeMachine.1"])
        #expect(items.first { $0.path == device }?.size ?? 0 >= 4_096)
        #expect(items.first { $0.path == device }?.hint == "old")
        #expect(items.first { $0.reportOnly }?.size == 0)
        #expect(result.rule("sims")?.errors.contains { $0.contains("protected") } == true)
    }

    @Test func unknownProbeIsReportedNotFatal() async throws {
        let home = try TempDirectory()
        let result = await ScanEngine().scan([probeRule("x", probe: "missing.probe")], context: context(home))
        #expect(result.rule("x")?.errors == ["unknown probe missing.probe"])
        #expect(result.isComplete)
    }

    @Test func cancellationReturnsIncompleteResult() async throws {
        let home = try TempDirectory()
        let engine = ScanEngine(registry: ProbeRegistry([SlowProbe()]))
        let rules = [probeRule("slow", probe: SlowProbe.id)]
        let ctx = context(home)
        let task = Task { await engine.scan(rules, context: ctx) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value
        #expect(!result.isComplete)
    }
}
