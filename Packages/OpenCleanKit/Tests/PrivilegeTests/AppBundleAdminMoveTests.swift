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

    @Test func rendersExactlyStageVerifyChownHandOver() throws {
        let fixture = try Fixture()
        let move = try fixture.move()
        let owner = "\(getuid()):\(getgid())"
        let staging = move.stagingDirectory
        let staged = staging + "/Foo.app"
        let source = try #require(FileStat.of(fixture.app))
        #expect(move.uid == getuid())
        #expect(move.gid == getgid())
        #expect(move.sourceDevice == source.device && move.sourceInode == source.inode)
        #expect(move.stagingBundle == staged)
        #expect(AppBundleAdminMove.split(staging).parent == "/private/var/tmp")
        #expect(AppBundleAdminMove.split(staging).name.starts(with: "openclean-uninstall."))
        let expected =
            "'/bin/mkdir' '-m' '700' '--' '\(staging)'"
            + " && { '/bin/mv' '-n' '--' '\(fixture.app)' '\(staged)' || { '/bin/rmdir' '--' '\(staging)'; false; }; }"
            + " && [ \"$('/usr/bin/stat' '-f' '%d:%i' '\(staged)')\" = '\(source.device):\(source.inode)' ]"
            + " && '/usr/bin/find' '\(staged)' '(' '-type' 'd' '-o' '(' '-type' 'f' '-o' '-type' 'l' ')'"
            + " '-links' '1' ')' '-exec' '/usr/sbin/chown' '-h' '--' '\(owner)' '{}' '+'"
            + " && '/usr/sbin/chown' '-h' '--' '\(owner)' '\(staging)'"
        #expect(move.shellText == expected)
        // Root never touches the quarantine destination (it is inside a folder the user can write).
        #expect(!move.shellText.contains(fixture.destination))
        #expect(!move.shellText.contains(fixture.items))
        #expect(
            AdminCommandBuilder.appleScript(forShellCommand: move.shellText)
                == "do shell script \"\(move.shellText.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        )
        #expect(try fixture.move().stagingDirectory != staging)
    }

    @Test func quotesNamesWithShellAndAppleScriptMetacharacters() throws {
        let name = #"Foo's "$(x)" \ App.app"#
        let fixture = try Fixture(name: name)
        let move = try fixture.move()
        let quotedName = #"Foo'\''s "$(x)" \ App.app"#
        #expect(move.shellText.contains("'" + fixture.applications + "/" + quotedName + "'"))
        #expect(move.shellText.contains("'" + move.stagingDirectory + "/" + quotedName + "'"))
        let script = AdminCommandBuilder.appleScript(forShellCommand: move.shellText)
        #expect(script.contains(#"Foo'\\''s \"$(x)\" \\ App.app"#))
        defer { Self.cleanUp(move) }
        let output = try ProcessCommandRunner().run("/bin/sh", ["-c", move.shellText])
        #expect(output.status == 0)
        #expect(move.finishAsUser() == .moved)
        #expect(FileStat.of(fixture.destination + "/Contents/Info.plist") != nil)
    }

    @Test func runningTheTextAsTheUserStagesThenFinishMovesIntoQuarantine() throws {
        let fixture = try Fixture()
        let move = try fixture.move()
        defer { Self.cleanUp(move) }
        let output = try ProcessCommandRunner().run("/bin/sh", ["-c", move.shellText])
        #expect(output.status == 0)
        #expect(FileStat.of(fixture.app) == nil)
        #expect(FileStat.of(fixture.destination) == nil)
        let staged = try #require(FileStat.of(move.stagingBundle))
        #expect(staged.inode == move.sourceInode && staged.ownerUID == getuid())
        var info = Darwin.stat()
        #expect(lstat(move.stagingDirectory, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)

        #expect(move.finishAsUser() == .moved)
        #expect(FileStat.of(fixture.destination + "/Contents/Info.plist") != nil)
        #expect(FileStat.of(fixture.destination)?.inode == move.sourceInode)
        #expect(FileStat.of(move.stagingDirectory) == nil)
    }

    @Test func finishMovesABundleThatIsNotWritableByItsOwner() throws {
        let fixture = try Fixture()
        let move = try fixture.move()
        defer { Self.cleanUp(move) }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.destination) }
        // Root can move a 0555 bundle; the non-root stand-in can't, so make it 0555 once it is staged.
        #expect(try ProcessCommandRunner().run("/bin/sh", ["-c", move.shellText]).status == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: move.stagingBundle)
        #expect(move.finishAsUser() == .moved)
        var info = Darwin.stat()
        #expect(lstat(fixture.destination, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o555)
    }

    /// Something planted at the destination while the prompt is open is never entered, replaced or chowned:
    /// the bundle stays in the staging folder and the failure says where it is.
    @Test func aDestinationPlantedDuringThePromptIsNeverTouched() throws {
        let fixture = try Fixture()
        let move = try fixture.move()
        defer { Self.cleanUp(move) }
        let planted = try fixture.dir.directory("Quarantine/S/items/0/Foo.app")
        let marker = try fixture.dir.file("Quarantine/S/items/0/Foo.app/marker", bytes: 3)
        let before = try #require(FileStat.of(marker))
        let plantedBefore = try #require(FileStat.of(planted))
        var markerInfo = Darwin.stat()
        #expect(lstat(marker, &markerInfo) == 0)
        let ctimeBefore = markerInfo.st_ctimespec

        #expect(try ProcessCommandRunner().run("/bin/sh", ["-c", move.shellText]).status == 0)
        guard case .stranded(let whereabouts) = move.finishAsUser() else {
            Issue.record("a planted destination must not be accepted")
            return
        }
        #expect(whereabouts.contains(move.stagingBundle))
        #expect(FileStat.of(move.stagingBundle)?.inode == move.sourceInode)
        #expect(FileStat.of(planted)?.inode == plantedBefore.inode)
        #expect(try FileManager.default.contentsOfDirectory(atPath: planted) == ["marker"])
        #expect(FileStat.of(marker) == before)
        #expect(lstat(marker, &markerInfo) == 0)
        #expect(markerInfo.st_ctimespec.tv_sec == ctimeBefore.tv_sec)
        #expect(markerInfo.st_ctimespec.tv_nsec == ctimeBefore.tv_nsec)
    }

    /// A bundle swapped in the Applications folder after validation is staged but never chowned.
    @Test func aSwappedSourceIsNeverChowned() throws {
        let fixture = try Fixture()
        let move = try fixture.move()
        defer { Self.cleanUp(move) }
        try FileManager.default.moveItem(atPath: fixture.app, toPath: fixture.applications + "/Real.app")
        let impostorFile = try fixture.dir.file("Applications/Foo.app/payload", bytes: 3)
        let ctimeBefore = Self.ctime(impostorFile)
        usleep(20_000)

        let output = try ProcessCommandRunner().run("/bin/sh", ["-c", move.shellText])
        #expect(output.status != 0)
        #expect(Self.ctime(move.stagingBundle + "/payload") == ctimeBefore)
        guard case .stranded = move.finishAsUser() else {
            Issue.record("an impostor must never be moved into quarantine")
            return
        }
        #expect(FileStat.of(fixture.destination) == nil)
        #expect(FileStat.of(fixture.applications + "/Real.app") != nil)
    }

    /// Files with more than one hard link could be links to files elsewhere: they are never chowned.
    @Test func filesWithSeveralHardLinksAreNotChowned() throws {
        let fixture = try Fixture()
        let single = try fixture.dir.file("Applications/Foo.app/Contents/single", bytes: 3)
        let linked = try fixture.dir.file("Applications/Foo.app/Contents/linked", bytes: 3)
        try FileManager.default.linkItem(atPath: linked, toPath: fixture.dir.path + "/outside")
        let move = try fixture.move()
        defer { Self.cleanUp(move) }
        let singleBefore = Self.ctime(single)
        let linkedBefore = Self.ctime(linked)
        usleep(20_000)

        #expect(try ProcessCommandRunner().run("/bin/sh", ["-c", move.shellText]).status == 0)
        #expect(Self.ctime(move.stagingBundle + "/Contents/single") != singleBefore)
        #expect(Self.ctime(move.stagingBundle + "/Contents/linked") == linkedBefore)
        #expect(Self.ctime(fixture.dir.path + "/outside") == linkedBefore)
        #expect(move.finishAsUser() == .moved)
    }

    @Test func aFailedMoveLeavesNoStagingFolderAndNothingStaged() throws {
        let fixture = try Fixture()
        let move = try fixture.move()
        defer { Self.cleanUp(move) }
        try FileManager.default.moveItem(atPath: fixture.app, toPath: fixture.applications + "/Gone.app")
        #expect(try ProcessCommandRunner().run("/bin/sh", ["-c", move.shellText]).status != 0)
        #expect(FileStat.of(move.stagingDirectory) == nil)
        guard case .stranded = move.finishAsUser() else {
            Issue.record("a vanished app must be reported")
            return
        }
        try FileManager.default.moveItem(atPath: fixture.applications + "/Gone.app", toPath: fixture.app)
        #expect(move.finishAsUser() == .notMoved)
    }

    @Test func aPreCreatedStagingFolderStopsTheScript() throws {
        let fixture = try Fixture()
        let move = try fixture.move()
        defer { Self.cleanUp(move) }
        try FileManager.default.createDirectory(atPath: move.stagingDirectory, withIntermediateDirectories: false)
        #expect(try ProcessCommandRunner().run("/bin/sh", ["-c", move.shellText]).status != 0)
        #expect(FileStat.of(fixture.app) != nil)
        #expect(move.finishAsUser() == .notMoved)
    }

    @Test func bundlesWithFoldersTheUserOwnsOrCanWriteAreNeverPrompted() throws {
        let fixture = try Fixture()
        let move = try fixture.move()
        #expect(move.sealProblem() == AppBundleAdminMoveError.bundleNotSealed.description)

        let runner = FakeCommandRunner()
        #expect(
            OsascriptAdminExecutor(runner: runner).runAsAdmin(move)
                == .failed(AppBundleAdminMoveError.bundleNotSealed.description))
        #expect(runner.calls.isEmpty)

        try FileManager.default.moveItem(atPath: fixture.app, toPath: fixture.applications + "/Other.app")
        try fixture.dir.directory("Applications/Foo.app")
        #expect(move.sealProblem() == AppBundleAdminMoveError.sourceChanged.description)
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

        // `runAsAdmin(_: AppBundleAdminMove)` refuses unsealed (user-owned) test bundles before prompting,
        // so the prompt and outcome mapping are exercised through `runPrompted` directly.
        let runner = FakeCommandRunner()
        runner.respond("/usr/bin/osascript -e \(script)", status: 0)
        #expect(OsascriptAdminExecutor(runner: runner).runPrompted(move.shellText) == .succeeded)
        #expect(runner.calls.count == 1)

        let cancelled = FakeCommandRunner()
        cancelled.respond("/usr/bin/osascript -e \(script)", status: 1, stderr: "User canceled. (-128)")
        #expect(OsascriptAdminExecutor(runner: cancelled).runPrompted(move.shellText) == .cancelled)

        let failing = FakeCommandRunner()
        failing.respond("/usr/bin/osascript -e \(script)", status: 1, stderr: "mv: Operation not permitted")
        #expect(
            OsascriptAdminExecutor(runner: failing).runPrompted(move.shellText)
                == .failed("mv: Operation not permitted"))
    }

    struct ChangeTime: Equatable {
        let seconds: Int
        let nanoseconds: Int
    }

    static func ctime(_ path: String) -> ChangeTime? {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return nil }
        return ChangeTime(seconds: info.st_ctimespec.tv_sec, nanoseconds: info.st_ctimespec.tv_nsec)
    }

    /// Removes a test's staging folder in /private/var/tmp, whatever state it was left in.
    static func cleanUp(_ move: AppBundleAdminMove) {
        guard FileStat.of(move.stagingDirectory) != nil else { return }
        _ = try? ProcessCommandRunner().run("/bin/chmod", ["-R", "u+rwx", move.stagingDirectory])
        try? FileManager.default.removeItem(atPath: move.stagingDirectory)
    }
}
