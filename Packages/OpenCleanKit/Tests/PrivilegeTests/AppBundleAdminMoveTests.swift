import Darwin
import Foundation
import ProcessKit
import RuleKit
import TestSupport
import Testing

@testable import Privilege

struct AppBundleAdminMoveTests {
    /// `<tmp>/Applications/Foo.app` and an empty session `<tmp>/Quarantine/S/items/0/`.
    struct Fixture {
        let dir: TempDirectory
        let applications: String
        let app: String
        let items: String
        let destination: String

        init(name: String = "Foo.app", bundleID: String = "com.example.foo") throws {
            dir = try TempDirectory()
            applications = try dir.directory("Applications")
            app = try dir.fakeApp("Applications/" + name, bundleID: bundleID)
            items = try dir.directory("Quarantine/S/items")
            try dir.directory("Quarantine/S/items/0")
            destination = items + "/0/" + name
        }

        func move(
            source: String? = nil, destination: String? = nil, bundleID: String = "com.example.foo",
            folders: [String]? = nil, items: String? = nil, protectedPaths: [String] = []
        ) throws -> AppBundleAdminMove {
            try AppBundleAdminMove(
                source: source ?? app, destination: destination ?? self.destination, bundleID: bundleID,
                applicationFolders: folders ?? [applications], sessionItemsDirectory: items ?? self.items,
                protectedPaths: protectedPaths)
        }

        func refusal(
            source: String? = nil, destination: String? = nil, bundleID: String = "com.example.foo",
            folders: [String]? = nil, items: String? = nil, protectedPaths: [String] = []
        ) -> AppBundleAdminMoveError? {
            do {
                _ = try move(
                    source: source, destination: destination, bundleID: bundleID, folders: folders, items: items,
                    protectedPaths: protectedPaths)
                return nil
            } catch let error as AppBundleAdminMoveError {
                return error
            } catch {
                Issue.record("unexpected error \(error)")
                return nil
            }
        }
    }

    @Test func rendersExactlyMoveThenChown() throws {
        let fixture = try Fixture()
        let move = try fixture.move()
        let owner = "\(getuid()):\(getgid())"
        #expect(move.uid == getuid())
        #expect(move.gid == getgid())
        #expect(
            move.steps == [
                ["/bin/mv", "-n", "--", fixture.app, fixture.destination],
                ["/usr/sbin/chown", "-R", "--", owner, fixture.destination],
            ])
        #expect(
            move.shellText
                == "'/bin/mv' '-n' '--' '\(fixture.app)' '\(fixture.destination)' && '/usr/sbin/chown' '-R' '--' '\(owner)' '\(fixture.destination)'"
        )
        #expect(
            AdminCommandBuilder.appleScript(forShellCommand: move.shellText)
                == "do shell script \"\(move.shellText)\" with administrator privileges")
    }

    @Test func quotesNamesWithShellAndAppleScriptMetacharacters() throws {
        let name = #"Foo's "$(x)" \ App.app"#
        let fixture = try Fixture(name: name)
        let move = try fixture.move()
        let quotedName = #"Foo'\''s "$(x)" \ App.app"#
        #expect(move.shellText.contains("'" + fixture.applications + "/" + quotedName + "'"))
        let script = AdminCommandBuilder.appleScript(forShellCommand: move.shellText)
        #expect(script.contains(#"Foo'\\''s \"$(x)\" \\ App.app"#))
    }

    @Test func runningTheTextAsTheUserMovesOnlyTheBundle() throws {
        let fixture = try Fixture()
        let move = try fixture.move()
        let output = try ProcessCommandRunner().run("/bin/sh", ["-c", move.shellText])
        #expect(output.status == 0)
        #expect(FileStat.of(fixture.app) == nil)
        #expect(FileStat.of(fixture.destination + "/Contents/Info.plist") != nil)
        #expect(FileStat.of(fixture.destination)?.ownerUID == getuid())
    }

    @Test func refusesSymlinkedSources() throws {
        let fixture = try Fixture()
        let link = try fixture.dir.symlink("Applications/Link.app", to: fixture.app)
        let linkedFolder = try fixture.dir.symlink("AppsLink", to: fixture.applications)
        #expect(fixture.refusal(source: link, destination: fixture.items + "/0/Link.app") == .sourceHasSymlink)
        #expect(
            fixture.refusal(source: linkedFolder + "/Foo.app", folders: [fixture.applications, linkedFolder])
                == .sourceHasSymlink)
    }

    @Test func refusesNonCanonicalOrMissingSources() throws {
        let fixture = try Fixture()
        #expect(fixture.refusal(source: fixture.applications + "/../Applications/Foo.app") == .sourceNotCanonical)
        #expect(fixture.refusal(source: "Applications/Foo.app") == .sourceNotCanonical)
        #expect(fixture.refusal(source: fixture.app + "/") == .sourceNotCanonical)
        #expect(fixture.refusal(source: fixture.app + "\nx") == .sourceNotCanonical)
        #expect(fixture.refusal(source: fixture.applications + "/Gone.app") == .sourceMissing)
    }

    @Test func refusesAnythingButAnAppDirectlyInsideAnApplicationsFolder() throws {
        let fixture = try Fixture()
        let nested = try fixture.dir.fakeApp("Applications/Sub/N.app", bundleID: "com.example.n")
        let folder = try fixture.dir.directory("Applications/Folder")
        let file = try fixture.dir.file("Applications/File.app")
        let elsewhere = try fixture.dir.fakeApp("Elsewhere/E.app", bundleID: "com.example.e")
        #expect(fixture.refusal(source: nested, destination: fixture.items + "/0/N.app") == .outsideApplicationFolders)
        #expect(
            fixture.refusal(source: elsewhere, destination: fixture.items + "/0/E.app") == .outsideApplicationFolders)
        #expect(fixture.refusal(folders: [fixture.dir.path + "/Elsewhere"]) == .outsideApplicationFolders)
        #expect(fixture.refusal(folders: []) == .outsideApplicationFolders)
        #expect(fixture.refusal(source: folder, destination: fixture.items + "/0/Folder") == .notAnAppBundle)
        #expect(fixture.refusal(source: file, destination: fixture.items + "/0/File.app") == .notAnAppBundle)
        #expect(fixture.refusal(source: "/System/Applications/Calculator.app") == .systemLocation)
    }

    @Test func refusesAppleAndOpenCleanBundles() throws {
        let fixture = try Fixture()
        #expect(fixture.refusal(bundleID: "com.apple.Safari") == .appleApp)
        #expect(fixture.refusal(bundleID: "COM.APPLE.Safari") == .appleApp)
        #expect(fixture.refusal(bundleID: AppBundleAdminMove.openCleanBundleID) == .openClean)
        #expect(fixture.refusal(protectedPaths: [fixture.app]) == .openClean)
        #expect(fixture.refusal(protectedPaths: [fixture.app + "/Contents"]) == .openClean)
        #expect(fixture.refusal(bundleID: "com.example.other") == .bundleIDMismatch)

        let apple = try Fixture(bundleID: "com.apple.Thing")
        #expect(apple.refusal(bundleID: "com.example.foo") == .appleApp)
        let openClean = try Fixture(bundleID: AppBundleAdminMove.openCleanBundleID)
        #expect(openClean.refusal(bundleID: "com.example.foo") == .openClean)
    }

    @Test func refusesDestinationsOutsideTheSessionOrAlreadyThere() throws {
        let fixture = try Fixture()
        let sibling = try fixture.dir.directory("Quarantine/S/other/0")
        #expect(fixture.refusal(destination: sibling + "/Foo.app") == .destinationOutsideSession)
        #expect(fixture.refusal(destination: fixture.dir.path + "/Foo.app") == .destinationOutsideSession)
        #expect(fixture.refusal(destination: fixture.items) == .destinationOutsideSession)
        #expect(fixture.refusal(destination: fixture.items + "/1/Foo.app") == .destinationOutsideSession)
        #expect(fixture.refusal(destination: fixture.items + "/0/../0/Foo.app") == .destinationNotCanonical)
        #expect(fixture.refusal(destination: fixture.items + "/0/Bar.app") == .destinationNameMismatch)
        #expect(fixture.refusal(items: sibling) == .destinationOutsideSession)

        try fixture.dir.directory("Quarantine/S/items/0/Foo.app")
        #expect(fixture.refusal() == .destinationExists)
    }

    @Test func refusesDestinationsReachedThroughSymlinks() throws {
        let fixture = try Fixture()
        let target = try fixture.dir.directory("Target")
        try fixture.dir.symlink("Quarantine/S/items/0/Foo.app", to: target)
        #expect(fixture.refusal() == .destinationExists)

        let other = try Fixture()
        let linkedItems = try other.dir.symlink("LinkedItems", to: other.items)
        #expect(
            other.refusal(destination: linkedItems + "/0/Foo.app", items: linkedItems) == .destinationOutsideSession)
        try FileManager.default.createSymbolicLink(atPath: other.items + "/2", withDestinationPath: target)
        #expect(other.refusal(destination: other.items + "/2/Foo.app") == .destinationOutsideSession)
    }

    @Test func osascriptExecutorRunsOnePromptAndMapsOutcomes() throws {
        let fixture = try Fixture()
        let move = try fixture.move()
        let script = AdminCommandBuilder.appleScript(forShellCommand: move.shellText)

        let runner = FakeCommandRunner()
        runner.respond("/usr/bin/osascript -e \(script)", status: 0)
        #expect(OsascriptAdminExecutor(runner: runner).runAsAdmin(move) == .succeeded)
        #expect(runner.calls.count == 1)

        let cancelled = FakeCommandRunner()
        cancelled.respond("/usr/bin/osascript -e \(script)", status: 1, stderr: "User canceled. (-128)")
        #expect(OsascriptAdminExecutor(runner: cancelled).runAsAdmin(move) == .cancelled)

        let failing = FakeCommandRunner()
        failing.respond("/usr/bin/osascript -e \(script)", status: 1, stderr: "mv: Operation not permitted")
        #expect(OsascriptAdminExecutor(runner: failing).runAsAdmin(move) == .failed("mv: Operation not permitted"))
    }
}
