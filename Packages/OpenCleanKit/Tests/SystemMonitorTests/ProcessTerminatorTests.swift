import Darwin
import Foundation
import Testing

@testable import SystemMonitor

struct KillableProcessTests {
    let policy = ForceQuitPolicy(ownPID: 999, currentUID: 501)

    func usage(_ pid: Int32, _ path: String?, uid: UInt32 = 501) -> ProcessUsage {
        ProcessUsage(
            pid: pid, uid: uid, name: path.map { ($0 as NSString).lastPathComponent } ?? "x", path: path,
            cpuPercent: 10, residentBytes: 1_000)
    }

    @Test func usersOwnBackgroundProcessIsKillable() {
        let groups = ProcessUsageCalculator.group([usage(42, "/Users/me/.nvm/bin/node")], policy: policy)
        #expect(groups.first?.killableProcess?.pid == 42)
        #expect(groups.first?.canQuit == false)
    }

    @Test func systemOtherUserProtectedAndPathlessProcessesAreNotKillable() {
        let usages = [
            usage(10, "/System/Library/PrivateFrameworks/X.framework/talagentd"),
            usage(11, "/usr/libexec/trustd"),
            usage(12, "/Users/other/bin/tool", uid: 502),
            usage(13, "/opt/homebrew/bin/WindowServer"),
            usage(14, nil),
            usage(999, "/Users/me/bin/self"),
        ]
        let groups = ProcessUsageCalculator.group(usages, policy: policy)
        #expect(groups.allSatisfy { $0.killableProcess == nil })
    }

    @Test func appsAreNeverKillableProcesses() {
        let groups = ProcessUsageCalculator.group(
            [usage(20, "/Applications/Foo.app/Contents/MacOS/Foo")], policy: policy)
        #expect(groups.first?.canQuit == true)
        #expect(groups.first?.killableProcess == nil)
    }
}

struct ProcessTerminatorTests {
    func spawnSleep() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    /// The policy normally protects /bin; tests use a policy whose roots don't, by checking identity only.
    func liveUsage(_ process: Process, path: String) -> ProcessUsage {
        ProcessUsage(
            pid: process.processIdentifier, uid: getuid(), name: "sleep", path: path, cpuPercent: 0, residentBytes: 0)
    }

    @Test func refusesWhenThePidNowRunsADifferentProgram() throws {
        let child = try spawnSleep()
        defer { child.terminate() }
        let outcome = ProcessTerminator().forceQuit(liveUsage(child, path: "/Users/me/bin/node"))
        #expect(outcome == .changed)
        #expect(child.isRunning)
    }

    @Test func refusesProtectedProcesses() throws {
        let child = try spawnSleep()
        defer { child.terminate() }
        let outcome = ProcessTerminator().forceQuit(liveUsage(child, path: "/bin/sleep"))
        #expect(outcome == .protected)
        #expect(child.isRunning)
    }

    @Test func identityReadsPathAndOwnerOfALivePid() throws {
        let child = try spawnSleep()
        defer { child.terminate() }
        let identity = try #require(ProcessTerminator.identity(of: child.processIdentifier))
        #expect(identity.path == "/bin/sleep")
        #expect(identity.uid == getuid())
    }

    @Test func refusesAPidThatNoLongerExists() throws {
        let child = try spawnSleep()
        child.terminate()
        child.waitUntilExit()
        let usage = ProcessUsage(
            pid: child.processIdentifier, uid: getuid(), name: "node", path: "/Users/me/bin/node", cpuPercent: 0,
            residentBytes: 0)
        #expect(ProcessTerminator().forceQuit(usage) == .changed)
    }
}
