import Foundation
import ProcessKit
import TestSupport
import Testing

@testable import Privilege

struct MaintenanceAdminCommandTests {
    @Test func everyCommandRendersExactlyTheExpectedShellText() throws {
        let expected: [MaintenanceAdminCommand: String] = [
            .flushDNSCache: "'/usr/bin/dscacheutil' '-flushcache' && '/usr/bin/killall' '-HUP' 'mDNSResponder'",
            .reindexSpotlight: "'/usr/bin/mdutil' '-E' '/'",
            .runPeriodicScripts: "'/usr/sbin/periodic' 'daily' 'weekly' 'monthly'",
            .thinLocalSnapshots: "'/usr/bin/tmutil' 'thinlocalsnapshots' '/' '999999999999' '4'",
        ]
        #expect(Set(expected.keys) == Set(MaintenanceAdminCommand.allCases), "a new case needs an expected rendering")
        for (command, text) in expected {
            #expect(try command.shellText() == text, "\(command)")
        }
    }

    @Test func everyCommandRendersExactlyTheExpectedArgv() {
        #expect(
            MaintenanceAdminCommand.flushDNSCache.steps == [
                ["/usr/bin/dscacheutil", "-flushcache"], ["/usr/bin/killall", "-HUP", "mDNSResponder"],
            ])
        #expect(MaintenanceAdminCommand.reindexSpotlight.steps == [["/usr/bin/mdutil", "-E", "/"]])
        #expect(
            MaintenanceAdminCommand.runPeriodicScripts.steps == [["/usr/sbin/periodic", "daily", "weekly", "monthly"]])
        #expect(
            MaintenanceAdminCommand.thinLocalSnapshots.steps == [
                ["/usr/bin/tmutil", "thinlocalsnapshots", "/", "999999999999", "4"]
            ])
    }

    @Test func executablesAreAbsoluteAndAllowListed() {
        for command in MaintenanceAdminCommand.allCases {
            for executable in command.executables {
                #expect(executable.hasPrefix("/"), "\(command): \(executable)")
                #expect(MaintenanceAdminCommand.allowedExecutables.contains(executable), "\(command): \(executable)")
            }
        }
        #expect(!MaintenanceAdminCommand.allowedExecutables.contains("/bin/sh"))
        #expect(!MaintenanceAdminCommand.allowedExecutables.contains("/bin/rm"))
    }

    @Test func unknownIdentifiersAreRejected() throws {
        for bad in ["", "rm", "flushDNSCache; rm -rf /", "/bin/sh", "FLUSHDNSCACHE", "purge"] {
            #expect(MaintenanceAdminCommand(rawValue: bad) == nil, "\(bad)")
        }
        let decoded = try? JSONDecoder().decode(MaintenanceAdminCommand.self, from: Data(#""runArbitrary""#.utf8))
        #expect(decoded == nil)
    }

    @Test func appleScriptWrapsTheFixedTextOnce() throws {
        let text = try MaintenanceAdminCommand.reindexSpotlight.shellText()
        #expect(
            AdminCommandBuilder.appleScript(forShellCommand: text)
                == #"do shell script "'/usr/bin/mdutil' '-E' '/'" with administrator privileges"#)
    }

    @Test func osascriptExecutorRunsOnePromptAndMapsOutcomes() {
        let script = AdminCommandBuilder.appleScript(
            forShellCommand: (try? MaintenanceAdminCommand.flushDNSCache.shellText()) ?? "")
        let runner = FakeCommandRunner()
        runner.respond("/usr/bin/osascript -e \(script)", status: 0)
        #expect(OsascriptAdminExecutor(runner: runner).runAsAdmin(.flushDNSCache) == .succeeded)
        #expect(runner.calls.count == 1)

        let cancelled = FakeCommandRunner()
        cancelled.respond("/usr/bin/osascript -e \(script)", status: 1, stderr: "User canceled. (-128)")
        #expect(OsascriptAdminExecutor(runner: cancelled).runAsAdmin(.flushDNSCache) == .cancelled)

        let failing = FakeCommandRunner()
        failing.respond("/usr/bin/osascript -e \(script)", status: 1, stderr: "boom")
        #expect(OsascriptAdminExecutor(runner: failing).runAsAdmin(.flushDNSCache) == .failed("boom"))
    }

    @Test func fakeExecutorRecordsWithoutPrompting() {
        let fake = FakeMaintenanceAdminExecutor(outcome: .cancelled)
        #expect(fake.runAsAdmin(.thinLocalSnapshots) == .cancelled)
        #expect(fake.commands == [.thinLocalSnapshots])
    }
}
