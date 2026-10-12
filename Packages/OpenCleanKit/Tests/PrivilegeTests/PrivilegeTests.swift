import Foundation
import ProcessKit
import Testing
import TestSupport
@testable import Privilege

struct AdminCommandBuilderTests {
    @Test func quotesForTheShell() {
        #expect(AdminCommandBuilder.shellQuote("plain") == "'plain'")
        #expect(AdminCommandBuilder.shellQuote("a'b") == #"'a'\''b'"#)
    }

    @Test func escapesForAppleScript() {
        #expect(AdminCommandBuilder.appleScriptLiteral(#"a"b\c"#) == #""a\"b\\c""#)
    }

    @Test func buildsOneRmInvocationWithEndOfOptions() throws {
        let command = try AdminCommandBuilder.removalCommand(paths: ["/Library/Caches/a", "/private/var/log/b.gz"]).text
        #expect(command == "/bin/rm -rf -- '/Library/Caches/a' '/private/var/log/b.gz'")
    }

    @Test func rejectsUnsafePaths() {
        #expect(throws: AdminCommandError.noPaths) { try AdminCommandBuilder.removalCommand(paths: []) }
        #expect(throws: AdminCommandError.invalidPath("relative")) {
            try AdminCommandBuilder.removalCommand(paths: ["relative"])
        }
        #expect(throws: AdminCommandError.invalidPath("/")) { try AdminCommandBuilder.removalCommand(paths: ["/"]) }
        #expect(throws: AdminCommandError.invalidPath("/a\nb")) {
            try AdminCommandBuilder.removalCommand(paths: ["/a\nb"])
        }
        for bad in ["/Library/Caches/x/", "/a//b", "/Library/./Caches/x", "/Library/Caches/../../Users/x"] {
            #expect(throws: AdminCommandError.invalidPath(bad)) { try AdminCommandBuilder.removalCommand(paths: [bad]) }
        }
        for bad in ["/a/../\u{0301}b", "/a/./\u{0301}b", "/a//\u{0301}b"] {
            #expect(throws: AdminCommandError.invalidPath(bad)) { try AdminCommandBuilder.removalCommand(paths: [bad]) }
        }
        // "/a/b/<U+0301>" is a literal file named U+0301 under /a/b (no trailing slash at byte level): accepted.
        #expect((try? AdminCommandBuilder.removalCommand(paths: ["/a/b/\u{0301}"])) != nil)
        let long = Array(repeating: "/Library/Caches/" + String(repeating: "x", count: 200), count: 5_000)
        #expect(throws: AdminCommandError.tooLong) { try AdminCommandBuilder.removalCommand(paths: long) }
    }

    @Test func hostileNamesAreRemovedLiterally() throws {
        let dir = try TempDirectory()
        let names = ["a'b", "$(touch PWNED)", "x\"y", "sp ace", "-rf", #"back\slash"#, "emoji 🧹", "semi;colon"]
        let paths = try names.map { try dir.file("victims/" + $0, bytes: 1) }
        try dir.file("victims/keep.txt", bytes: 1)

        let command = try AdminCommandBuilder.removalCommand(paths: paths).text
        let output = try ProcessCommandRunner().run("/bin/sh", ["-c", command])

        #expect(output.status == 0, "\(output.stderrText)")
        for path in paths { #expect(!FileManager.default.fileExists(atPath: path), "\(path) survived") }
        #expect(FileManager.default.fileExists(atPath: dir.path + "/victims/keep.txt"))
        #expect(!FileManager.default.fileExists(atPath: dir.path + "/victims/PWNED"))
        #expect(!FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/PWNED"))
    }

    @Test func appleScriptLiteralRoundTripsThroughOsascript() throws {
        let command = try AdminCommandBuilder.removalCommand(paths: [#"/tmp/a'b"c\d 🧹"#]).text
        let output = try ProcessCommandRunner().run(
            "/usr/bin/osascript", ["-e", "return " + AdminCommandBuilder.appleScriptLiteral(command)])
        #expect(output.status == 0, "\(output.stderrText)")
        #expect(output.stdoutText == command + "\n")
    }
}

struct OsascriptAdminExecutorTests {
    let command: RemovalCommand
    let script: String

    init() throws {
        command = try AdminCommandBuilder.removalCommand(paths: ["/Library/Caches/a"])
        script = AdminCommandBuilder.appleScript(forShellCommand: command.text)
    }

    @Test func runsOsascriptWithAdministratorPrivileges() {
        let runner = FakeCommandRunner()
        runner.respond("/usr/bin/osascript -e " + script)
        #expect(OsascriptAdminExecutor(runner: runner).runAsAdmin(command) == .succeeded)
        #expect(runner.calls == [["/usr/bin/osascript", "-e", script]])
        #expect(script.hasSuffix("with administrator privileges"))
    }

    @Test func mapsUserCancelToCancelled() {
        let runner = FakeCommandRunner()
        runner.respond(
            "/usr/bin/osascript -e " + script, status: 1,
            stderr: "0:105: execution error: User canceled. (-128)\n")
        #expect(OsascriptAdminExecutor(runner: runner).runAsAdmin(command) == .cancelled)
    }

    @Test func pathContaining128IsNotMistakenForCancel() {
        let runner = FakeCommandRunner()
        let stderr = "0:162: execution error: rm: /Library/Caches/cache-128: Permission denied (1)\n"
        runner.respond("/usr/bin/osascript -e " + script, status: 1, stderr: stderr)
        #expect(
            OsascriptAdminExecutor(runner: runner).runAsAdmin(command)
                == .failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test func mapsOtherErrorsToFailed() {
        let runner = FakeCommandRunner()
        runner.respond("/usr/bin/osascript -e " + script, status: 1, stderr: "rm: permission denied\n")
        #expect(OsascriptAdminExecutor(runner: runner).runAsAdmin(command) == .failed("rm: permission denied"))
    }
}
