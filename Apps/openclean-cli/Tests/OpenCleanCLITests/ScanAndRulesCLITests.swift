import Foundation
import TestSupport
import Testing

@Suite(.serialized)
struct ScanAndRulesCLITests {
    @Test func scanJSONReportsFixtureRules() throws {
        try CLIFixtures.withHome { home, env in
            try home.file("Library/Caches/com.example/blob", bytes: 8_192)
            let run = try CLIBinary.run(["scan", "--json"], environment: env)
            #expect(run.status == 0, "\(run.stderr)")
            let json = try CLIFixtures.json(run.stdout)
            #expect((json["totalBytes"] as? Int ?? 0) >= 8_192)
            let ids = (json["rules"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
            #expect(ids == ["fixture.caches", "fixture.downloads"])
        }
    }

    @Test func scanTextPrintsTotals() throws {
        try CLIFixtures.withHome { home, env in
            try home.file("Library/Caches/com.example/blob", bytes: 8_192)
            let run = try CLIBinary.run(["scan"], environment: env)
            #expect(run.status == 0)
            #expect(run.stdout.contains("Fixture caches [fixture.caches]"))
            #expect(run.stdout.contains("Total removable:"))
        }
    }

    @Test func lintAcceptsGoodAndRejectsBadPacks() throws {
        try CLIFixtures.withHome { home, env in
            let good = try CLIBinary.run(["rules", "lint", home.path + "/rules/fixture.yaml"], environment: env)
            #expect(good.status == 0)
            #expect(good.stdout.hasPrefix("OK: 1 pack(s), 3 rule(s)"))

            let badPath = home.path + "/bad.yaml"
            try
                "pack: bad\nversion: 1\nrules:\n  - id: bad.docs\n    name: D\n    category: user\n    explain: x\n    paths: [\"~/Documents/*\"]\n    safety: regenerable\n"
                .write(toFile: badPath, atomically: true, encoding: .utf8)
            let bad = try CLIBinary.run(["rules", "lint", badPath], environment: env)
            #expect(bad.status == 1)
            #expect(bad.stderr.contains("protected location"))
        }
    }

    @Test func rulesListAndExplain() throws {
        try CLIFixtures.withHome { home, env in
            let list = try CLIBinary.run(["rules", "list", "--json"], environment: env)
            #expect(list.status == 0)
            let rules = try CLIFixtures.json(list.stdout)["rules"] as? [[String: Any]]
            #expect(rules?.count == 3)

            let explain = try CLIBinary.run(["rules", "explain", "fixture.downloads"], environment: env)
            #expect(explain.status == 0)
            #expect(explain.stdout.contains("Test downloads you may not need."))

            let unknown = try CLIBinary.run(["rules", "explain", "nope"], environment: env)
            #expect(unknown.status == 1)
        }
    }

    @Test func usageErrorsExitWithOneAndHelpWithZero() throws {
        try CLIFixtures.withHome { _, env in
            let bad = try CLIBinary.run(["frobnicate"], environment: env)
            let help = try CLIBinary.run(["--help"], environment: env)
            let version = try CLIBinary.run(["--version"], environment: env)
            #expect(bad.status == 1)
            #expect(help.status == 0)
            #expect(version.stdout.contains("0.1.0"))
        }
    }

    @Test func binaryRefusesNonTemporaryHome() {
        #expect(throws: (any Error).self) { try CLIBinary.run(["--version"], environment: [:]) }
        #expect(throws: (any Error).self) {
            try CLIBinary.run(["--version"], environment: ["OPENCLEAN_HOME": "/Users"])
        }
    }
}
