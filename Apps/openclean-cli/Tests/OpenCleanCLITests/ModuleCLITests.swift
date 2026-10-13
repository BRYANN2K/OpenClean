import Foundation
import TestSupport
import Testing

/// `apps`, `space` and `performance` against the built binary and a fixture home. With `OPENCLEAN_HOME`
/// set, only `<home>/Applications` is listed, so the real `/Applications` is never touched. No test passes
/// `--allow-admin`, so no administrator prompt can appear.
@Suite(.serialized)
struct AppsCLITests {
    /// `<home>/Applications/Foo.app` with a bundle-id leftover (Caches) and a name-only one (Application Support).
    struct Fixture {
        let app: String
        let cache: String
        let named: String
    }

    static func makeFixture(_ home: TempDirectory, bundleID: String = "com.example.foo") throws -> Fixture {
        let app = try home.fakeApp("Applications/Foo.app", bundleID: bundleID, version: "1.2")
        let cache = try home.directory("Library/Caches/\(bundleID)")
        try home.file("Library/Caches/\(bundleID)/blob", bytes: 2_048)
        let named = try home.directory("Library/Application Support/Foo")
        return Fixture(app: app, cache: cache, named: named)
    }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    @Test func listShowsAppsWithLeftoversAsJSON() throws {
        try CLIFixtures.withHome { home, env in
            let fixture = try Self.makeFixture(home)
            let run = try CLIBinary.run(["apps", "list", "--json"], environment: env)
            #expect(run.status == 0, "\(run.stderr)")
            let json = try CLIFixtures.json(run.stdout)
            #expect(json["schema"] as? Int == 1)
            let apps = try #require(json["apps"] as? [[String: Any]])
            #expect(apps.count == 1)
            let app = try #require(apps.first)
            #expect(app["bundleID"] as? String == "com.example.foo")
            #expect(app["status"] as? String == "removable")
            #expect(app["version"] as? String == "1.2")
            let leftovers = try #require(app["leftovers"] as? [[String: Any]])
            #expect(Set(leftovers.compactMap { $0["kind"] as? String }) == ["caches", "applicationSupport"])
            #expect(leftovers.first { $0["match"] as? String == "bundleID" }?["selectedByDefault"] as? Bool == true)
            #expect((app["leftoverBytes"] as? Int ?? 0) > 0)
            #expect(Self.exists(fixture.app) && Self.exists(fixture.cache))

            let text = try CLIBinary.run(["apps", "list"], environment: env)
            #expect(text.status == 0)
            #expect(text.stdout.contains("Foo 1.2  [com.example.foo]"))
        }
    }

    @Test func dryRunMovesNothing() throws {
        try CLIFixtures.withHome { home, env in
            let fixture = try Self.makeFixture(home)
            let run = try CLIBinary.run(
                ["apps", "uninstall", "com.example.foo", "--dry-run", "--json"], environment: env)
            #expect(run.status == 0, "\(run.stderr)")
            let json = try CLIFixtures.json(run.stdout)
            #expect(json["schema"] as? Int == 1)
            #expect(json["paths"] as? [String] == [fixture.app, fixture.cache])
            #expect(json["requiresAdministrator"] as? Bool == false)
            #expect(Self.exists(fixture.app) && Self.exists(fixture.cache))
        }
    }

    @Test func refusesWithoutConfirmationWhenNotATerminal() throws {
        try CLIFixtures.withHome { home, env in
            let fixture = try Self.makeFixture(home)
            let run = try CLIBinary.run(["apps", "uninstall", "com.example.foo"], environment: env)
            #expect(run.status == 1)
            #expect(run.stderr.contains("Re-run with --yes"))
            #expect(Self.exists(fixture.app))

            let json = try CLIBinary.run(["apps", "uninstall", "com.example.foo", "--json"], environment: env)
            #expect(json.status == 1)
            #expect(json.stdout.isEmpty)
            #expect(json.stderr.contains("--json requires --yes or --dry-run"))
            #expect(Self.exists(fixture.app))
        }
    }

    @Test func yesQuarantinesAppAndBundleIDLeftoversAndRestoreBringsThemBack() throws {
        try CLIFixtures.withHome { home, env in
            let fixture = try Self.makeFixture(home)
            let run = try CLIBinary.run(["apps", "uninstall", "com.example.foo", "--yes", "--json"], environment: env)
            #expect(run.status == 0, "\(run.stderr)")
            let session = try #require(try CLIFixtures.json(run.stdout)["session"] as? [String: Any])
            let entries = try #require(session["entries"] as? [[String: Any]])
            #expect(entries.map { $0["path"] as? String } == [fixture.app, fixture.cache])
            #expect(entries.allSatisfy { $0["outcome"] as? String == "quarantined" })
            #expect(!Self.exists(fixture.app) && !Self.exists(fixture.cache))
            #expect(Self.exists(fixture.named))

            let id = try #require(session["id"] as? String)
            let restore = try CLIBinary.run(["restore", id], environment: env)
            #expect(restore.status == 0, "\(restore.stderr)")
            #expect(Self.exists(fixture.app + "/Contents/Info.plist") && Self.exists(fixture.cache + "/blob"))
        }
    }

    @Test func includeNameMatchesAlsoMovesNameLeftovers() throws {
        try CLIFixtures.withHome { home, env in
            let fixture = try Self.makeFixture(home)
            let run = try CLIBinary.run(
                ["apps", "uninstall", "com.example.foo", "--yes", "--include-name-matches"], environment: env)
            #expect(run.status == 0, "\(run.stderr)")
            #expect(!Self.exists(fixture.app) && !Self.exists(fixture.cache) && !Self.exists(fixture.named))
        }
    }

    @Test func unknownBundleIDIsAnError() throws {
        try CLIFixtures.withHome { home, env in
            let fixture = try Self.makeFixture(home)
            let run = try CLIBinary.run(["apps", "uninstall", "com.example.nope", "--yes"], environment: env)
            #expect(run.status == 1)
            #expect(run.stderr.contains("No installed app with bundle identifier com.example.nope"))
            #expect(Self.exists(fixture.app))
        }
    }

    @Test func appleAppsAreNeverUninstalled() throws {
        try CLIFixtures.withHome { home, env in
            let app = try home.fakeApp("Applications/Thing.app", bundleID: "com.apple.thing")
            let run = try CLIBinary.run(["apps", "uninstall", "com.apple.thing", "--yes"], environment: env)
            #expect(run.status == 1)
            #expect(run.stderr.contains("can't be uninstalled"))
            #expect(Self.exists(app))
        }
    }

    /// A bundle the user can't move needs the administrator password; like `clean`, it is dropped when
    /// stdin isn't a terminal unless `--allow-admin` is passed (never passed here).
    @Test func appThatNeedsAdministratorIsRefusedWhenNotATerminal() throws {
        try CLIFixtures.withHome { home, env in
            let fixture = try Self.makeFixture(home)
            let applications = home.path + "/Applications"
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: applications)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: applications) }

            let list = try CLIBinary.run(["apps", "list", "--json"], environment: env)
            let app = try #require((try CLIFixtures.json(list.stdout)["apps"] as? [[String: Any]])?.first)
            #expect(app["status"] as? String == "needsAdministrator")
            #expect(app["requiresAdministrator"] as? Bool == true)

            let dry = try CLIBinary.run(["apps", "uninstall", "com.example.foo", "--dry-run"], environment: env)
            #expect(dry.status == 0, "\(dry.stderr)")
            #expect(dry.stdout.contains("macOS will ask for your administrator password"))
            #expect(dry.stderr.contains("--allow-admin"))

            let run = try CLIBinary.run(["apps", "uninstall", "com.example.foo", "--yes"], environment: env)
            #expect(run.status == 1)
            #expect(
                run.stderr.contains(
                    "Foo needs the administrator password to uninstall; re-run in a terminal or pass --allow-admin."))
            #expect(Self.exists(fixture.app) && Self.exists(fixture.cache))
            let history = try CLIBinary.run(["history", "--json"], environment: env)
            #expect((try CLIFixtures.json(history.stdout)["sessions"] as? [Any])?.isEmpty == true)
        }
    }
}

@Suite(.serialized)
struct SpaceAndPerformanceCLITests {
    @Test func largeFilesHonourMinSizeAndOlderThan() throws {
        try CLIFixtures.withHome { home, env in
            let old = try home.file("Downloads/old.iso", bytes: 300_000)
            let recent = try home.file("Downloads/recent.iso", bytes: 500_000)
            try home.file("Downloads/small.iso", bytes: 1_000)
            let longAgo = Date(timeIntervalSinceNow: -400 * 86_400)
            var values = URLResourceValues()
            values.contentAccessDate = longAgo
            values.contentModificationDate = longAgo
            var url = URL(fileURLWithPath: old)
            try url.setResourceValues(values)

            let run = try CLIBinary.run(["space", "large", "--min-size", "100KB", "--json"], environment: env)
            #expect(run.status == 0, "\(run.stderr)")
            let json = try CLIFixtures.json(run.stdout)
            #expect(json["schema"] as? Int == 1)
            #expect(json["minimumBytes"] as? Int == 100_000)
            #expect(json["notOpenedForDays"] == nil)
            let files = try #require(json["files"] as? [[String: Any]])
            #expect(files.map { $0["path"] as? String } == [recent, old])

            let aged = try CLIBinary.run(
                ["space", "large", "--min-size", "100KB", "--older-than", "365", "--json"], environment: env)
            let agedJSON = try CLIFixtures.json(aged.stdout)
            #expect(agedJSON["notOpenedForDays"] as? Int == 365)
            #expect((agedJSON["files"] as? [[String: Any]])?.map { $0["path"] as? String } == [old])
            #expect(FileManager.default.fileExists(atPath: old) && FileManager.default.fileExists(atPath: recent))

            let text = try CLIBinary.run(["space", "large", "--min-size", "100KB"], environment: env)
            #expect(text.stdout.contains("2 file(s) at least 100 KB"))
            #expect(text.stdout.contains("Nothing was removed."))
        }
    }

    @Test func invalidMinSizeIsAnError() throws {
        try CLIFixtures.withHome { _, env in
            let run = try CLIBinary.run(["space", "large", "--min-size", "lots"], environment: env)
            #expect(run.status == 1)
        }
    }

    @Test func duplicatesAreGroupedAndNothingIsRemoved() throws {
        try CLIFixtures.withHome { home, env in
            let first = try home.file("Downloads/a.bin", bytes: 2_000_000)
            let second = try home.file("Pictures/a copy.bin", bytes: 2_000_000)
            try home.file("Music/unique.bin", bytes: 3_000_000)
            let run = try CLIBinary.run(["space", "duplicates", "--json"], environment: env)
            #expect(run.status == 0, "\(run.stderr)")
            let json = try CLIFixtures.json(run.stdout)
            #expect(json["schema"] as? Int == 1)
            let groups = try #require(json["groups"] as? [[String: Any]])
            #expect(groups.count == 1)
            let paths = (groups.first?["files"] as? [[String: Any]])?.compactMap { $0["path"] as? String }
            #expect(Set(paths ?? []) == [first, second])
            #expect(FileManager.default.fileExists(atPath: first) && FileManager.default.fileExists(atPath: second))
        }
    }

    @Test func performanceSnapshotIsReadOnlyJSON() throws {
        try CLIFixtures.withHome { _, env in
            let run = try CLIBinary.run(
                ["performance", "--json", "--interval", "0.2", "--limit", "3"], environment: env)
            #expect(run.status == 0, "\(run.stderr)")
            let json = try CLIFixtures.json(run.stdout)
            #expect(json["schema"] as? Int == 1)
            #expect(json["memory"] is [String: Any])
            #expect((json["topCPU"] as? [Any])?.count ?? 99 <= 3)
            #expect((json["topMemory"] as? [Any])?.count ?? 99 <= 3)

            let bad = try CLIBinary.run(["performance", "--interval", "60"], environment: env)
            #expect(bad.status == 1)
        }
    }
}
