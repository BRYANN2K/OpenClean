import Foundation
import ProcessKit
import ScanEngine
import Testing
import TestSupport
@testable import Probes

struct ProbesTests {
    func context(_ home: TempDirectory) -> ScanContext {
        ScanContext(home: home.path, hasFullDiskAccess: true, processChecker: FakeProcessChecker())
    }

    @Test func xcodeSimulatorsReportsOnlyUnavailableDevices() async throws {
        let home = try TempDirectory()
        let runner = FakeCommandRunner()
        runner.respond(
            "/usr/bin/xcrun simctl list devices --json",
            stdout: """
                {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-16-0": [
                  {"udid": "AAA", "name": "iPhone 14", "isAvailable": false},
                  {"udid": "BBB", "name": "iPhone 15", "isAvailable": true}
                ]}}
                """)
        let findings = try await XcodeSimulatorsProbe(runner: runner).scan(context(home))
        #expect(findings == [
            ProbeFinding(
                path: home.path + "/Library/Developer/CoreSimulator/Devices/AAA",
                hint: "Unavailable simulator: iPhone 14")
        ])
    }

    @Test func xcodeSimulatorsIsEmptyWhenXcrunFails() async throws {
        let home = try TempDirectory()
        let runner = FakeCommandRunner()
        runner.respond("/usr/bin/xcrun simctl list devices --json", status: 1)
        #expect(try await XcodeSimulatorsProbe(runner: runner).scan(context(home)).isEmpty)
    }

    @Test func homebrewCacheListsCacheEntries() async throws {
        let home = try TempDirectory()
        let brew = try home.file("bin/brew")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew)
        try home.file("brew-cache/a.bottle.tar.gz", bytes: 10)
        try home.file("brew-cache/downloads/x", bytes: 10)
        let runner = FakeCommandRunner()
        runner.respond("\(brew) --cache", stdout: home.path + "/brew-cache\n")
        let findings = try await HomebrewCacheProbe(runner: runner, brewCandidates: [brew]).scan(context(home))
        #expect(findings.map(\.path) == [home.path + "/brew-cache/a.bottle.tar.gz", home.path + "/brew-cache/downloads"])
        #expect(findings.allSatisfy { !$0.reportOnly })
    }

    @Test func homebrewCacheIsEmptyWithoutBrew() async throws {
        let home = try TempDirectory()
        let probe = HomebrewCacheProbe(runner: FakeCommandRunner(), brewCandidates: [home.path + "/missing/brew"])
        #expect(try await probe.scan(context(home)).isEmpty)
    }

    @Test func dockerDiskImageIsReportOnly() async throws {
        let home = try TempDirectory()
        let image = try home.file("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", bytes: 10)
        let findings = try await DockerDiskImageProbe().scan(context(home))
        #expect(findings.map(\.path) == [image])
        #expect(findings.allSatisfy { $0.reportOnly })
        #expect(findings.first?.hint?.contains("docker system prune") == true)
    }

    @Test func timeMachineSnapshotsAreVirtualReportOnlyFindings() async throws {
        let home = try TempDirectory()
        let runner = FakeCommandRunner()
        runner.respond(
            "/usr/bin/tmutil listlocalsnapshots /",
            stdout: "Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-01-101010.local\n")
        let findings = try await TimeMachineSnapshotsProbe(runner: runner).scan(context(home))
        #expect(findings.map(\.path) == ["tmsnapshot://com.apple.TimeMachine.2026-10-01-101010.local"])
        #expect(findings.allSatisfy { $0.reportOnly })
    }

    @Test func standardRegistryHasAllV1Probes() {
        #expect(ProbeRegistry.standard.ids == [
            "xcode.simulators", "homebrew.cache", "docker.disk-image", "timemachine.local-snapshots",
        ])
    }
}
