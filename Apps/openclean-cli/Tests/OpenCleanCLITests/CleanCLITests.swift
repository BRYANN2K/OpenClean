import Foundation
import Testing
import TestSupport

@Suite(.serialized)
struct CleanCLITests {
    @Test func dryRunRemovesNothing() throws {
        try CLIFixtures.withHome { home, env in
            let cache = try home.file("Library/Caches/com.example/blob", bytes: 10)
            let run = try CLIBinary.run(["clean", "--dry-run"], environment: env)
            #expect(run.status == 0, "\(run.stderr)")
            #expect(run.stdout.contains("Ready to remove 1 item(s)"))
            #expect(FileManager.default.fileExists(atPath: cache))
        }
    }

    @Test func refusesWithoutConfirmationWhenNotATerminal() throws {
        try CLIFixtures.withHome { home, env in
            let cache = try home.file("Library/Caches/com.example/blob", bytes: 10)
            let run = try CLIBinary.run(["clean"], environment: env)
            #expect(run.status == 1)
            #expect(run.stderr.contains("--yes"))
            #expect(FileManager.default.fileExists(atPath: cache))
        }
    }

    @Test func yesRemovesRegenerableOnly() throws {
        try CLIFixtures.withHome { home, env in
            let cache = try home.file("Library/Caches/com.example/blob", bytes: 10)
            let download = try home.file("Downloads/old.dmg", bytes: 10)
            let run = try CLIBinary.run(["clean", "--yes"], environment: env)
            #expect(run.status == 0, "\(run.stderr)")
            #expect(!FileManager.default.fileExists(atPath: cache))
            #expect(FileManager.default.fileExists(atPath: download))
        }
    }

    @Test func includeReviewQuarantinesAndRestoreBringsBack() throws {
        try CLIFixtures.withHome { home, env in
            let download = try home.file("Downloads/old.dmg", bytes: 10)
            let clean = try CLIBinary.run(["clean", "--yes", "--include-review", "--json"], environment: env)
            #expect(clean.status == 0, "\(clean.stderr)")
            #expect(!FileManager.default.fileExists(atPath: download))
            let session = try #require((try CLIFixtures.json(clean.stdout)["session"] as? [String: Any])?["id"] as? String)

            let history = try CLIBinary.run(["history", "--json"], environment: env)
            let sessions = try CLIFixtures.json(history.stdout)["sessions"] as? [[String: Any]]
            #expect(sessions?.first?["id"] as? String == session)

            let restore = try CLIBinary.run(["restore", session], environment: env)
            #expect(restore.status == 0, "\(restore.stderr)")
            #expect(FileManager.default.fileExists(atPath: download))
        }
    }

    @Test func exitsTwoWhenAnItemIsSkipped() throws {
        try CLIFixtures.withHome { home, env in
            let file = try home.file("Library/Caches/com.busy/store.db", bytes: 10)
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
            defer { try? handle.close() }
            let run = try CLIBinary.run(["clean", "--yes"], environment: env)
            #expect(run.status == 2, "\(run.stdout)\n\(run.stderr)")
            #expect(run.stdout.contains("open in another app"))
            #expect(FileManager.default.fileExists(atPath: file))
        }
    }

    @Test func unknownRuleIDIsAnError() throws {
        try CLIFixtures.withHome { _, env in
            let run = try CLIBinary.run(["clean", "--rule", "nope", "--dry-run"], environment: env)
            #expect(run.status == 1)
            #expect(run.stderr.contains("Unknown rule id"))
        }
    }

    @Test func jsonWithoutYesOrDryRunIsRefused() throws {
        try CLIFixtures.withHome { home, env in
            let cache = try home.file("Library/Caches/com.example/blob", bytes: 10)
            let run = try CLIBinary.run(["clean", "--json"], environment: env)
            #expect(run.status == 1)
            #expect(run.stdout.isEmpty)
            #expect(run.stderr.contains("--json requires --yes or --dry-run"))
            #expect(FileManager.default.fileExists(atPath: cache))
        }
    }

    @Test func cautionRuleSurvivesIncludeReview() throws {
        try CLIFixtures.withHome { home, env in
            let risky = try home.file("Risky/thing", bytes: 10)
            let download = try home.file("Downloads/old.dmg", bytes: 10)
            let run = try CLIBinary.run(["clean", "--yes", "--include-review"], environment: env)
            #expect(run.status == 0, "\(run.stderr)")
            #expect(!FileManager.default.fileExists(atPath: download))
            #expect(FileManager.default.fileExists(atPath: risky))
        }
    }
}
