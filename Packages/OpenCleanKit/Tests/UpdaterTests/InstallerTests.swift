import Foundation
import ProcessKit
import TestSupport
import Testing

@testable import Updater

/// Pretends to be hdiutil and codesign; runs the real `ditto` (a plain copy between temp folders).
final class ScriptedRunner: CommandRunner, @unchecked Sendable {
    let mountPoint: String
    var attachStatus: Int32 = 0
    var codesignStatus: Int32 = 0
    private let lock = NSLock()
    private var recorded: [[String]] = []

    init(mountPoint: String) {
        self.mountPoint = mountPoint
    }

    var calls: [[String]] { lock.withLock { recorded } }

    func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        lock.withLock { recorded.append([executable] + arguments) }
        switch executable {
        case "/usr/bin/hdiutil" where arguments.first == "attach":
            let plist: [String: Any] = [
                "system-entities": [
                    ["dev-entry": "/dev/disk9", "content-hint": "GUID_partition_scheme"],
                    ["dev-entry": "/dev/disk9s1", "mount-point": mountPoint],
                ]
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            return CommandOutput(status: attachStatus, stdout: attachStatus == 0 ? data : Data())
        case "/usr/bin/hdiutil":
            return CommandOutput(status: 0)
        case "/usr/bin/ditto":
            return try ProcessCommandRunner(timeout: 30).run(executable, arguments)
        case "/usr/bin/codesign":
            return CommandOutput(status: codesignStatus, stderr: Data("a sealed resource is missing".utf8))
        default:
            return CommandOutput(status: 127)
        }
    }
}

struct InstallerTests {
    static let bundleID = "io.github.leoanimesh.OpenClean"

    func verified(_ temp: TempDirectory, version: String = "0.3.0") throws -> VerifiedDownload {
        let dmg = try temp.file("Updates/\(version)/OpenClean-\(version).dmg", bytes: 10)
        let release = Release(
            version: SemanticVersion(version)!, tagName: "v\(version)", name: "", notes: "",
            htmlURL: ReleaseFeed.releasesPage, publishedAt: nil, assets: [])
        return VerifiedDownload(release: release, dmgPath: dmg, sha256: "")
    }

    @Test func stagesAndValidatesTheApp() throws {
        let temp = try TempDirectory()
        try temp.fakeApp("Volume/OpenClean.app", version: "0.3.0")
        let runner = ScriptedRunner(mountPoint: temp.path + "/Volume")
        let download = try verified(temp)
        let staged = try UpdateInstaller(runner: runner, bundleIdentifier: Self.bundleID).stage(download)

        #expect(staged.version == SemanticVersion("0.3.0"))
        #expect(staged.dmgPath == download.dmgPath)
        #expect(staged.appPath.hasPrefix(temp.path + "/Updates/0.3.0/staged-"))
        #expect(staged.appPath.hasSuffix("/OpenClean.app"))
        #expect(UpdateInstaller.bundleInfo(staged.appPath)?.version == "0.3.0")

        let commands = runner.calls.map { $0.prefix(2).joined(separator: " ") }
        #expect(
            commands == [
                "/usr/bin/hdiutil attach", "/usr/bin/ditto \(temp.path)/Volume/OpenClean.app",
                "/usr/bin/hdiutil detach",
                "/usr/bin/codesign --verify",
            ])
        #expect(
            runner.calls[0] == [
                "/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", download.dmgPath,
            ])
        #expect(runner.calls.last == ["/usr/bin/codesign", "--verify", "--deep", "--strict", staged.appPath])
    }

    @Test func detachesTheImageWhenTheMountPointIsUnusable() throws {
        let temp = try TempDirectory()
        // A relative mount point is rejected after a successful attach; the image must not stay mounted.
        let runner = ScriptedRunner(mountPoint: "relative/Volume")
        #expect(throws: UpdateError.stagingFailed("the disk image has no mountable volume")) {
            try UpdateInstaller(runner: runner, bundleIdentifier: Self.bundleID).stage(verified(temp))
        }
        #expect(runner.calls.dropFirst().map { Array($0.prefix(3)) } == [["/usr/bin/hdiutil", "detach", "/dev/disk9"]])
    }

    @Test func wholeDisksAcceptOnlyDeviceEntries() {
        #expect(UpdateInstaller.wholeDisk("/dev/disk4") == "/dev/disk4")
        #expect(UpdateInstaller.wholeDisk("/dev/disk4s12") == "/dev/disk4")
        #expect(UpdateInstaller.wholeDisk("/dev/disk") == nil)
        #expect(UpdateInstaller.wholeDisk("/dev/disk4s") == nil)
        #expect(UpdateInstaller.wholeDisk("/dev/disk4x1") == nil)
        #expect(UpdateInstaller.wholeDisk("/dev/rdisk4") == nil)
        #expect(UpdateInstaller.wholeDisk("/dev/disk4 -force") == nil)
    }

    @Test func refusesWrongBundleIdentifier() throws {
        let temp = try TempDirectory()
        try temp.fakeApp("Volume/OpenClean.app", bundleID: "com.example.Evil", version: "0.3.0")
        let runner = ScriptedRunner(mountPoint: temp.path + "/Volume")
        #expect(throws: UpdateError.invalidBundle("bundle identifier is com.example.Evil")) {
            try UpdateInstaller(runner: runner, bundleIdentifier: Self.bundleID).stage(verified(temp))
        }
        // Still detached after the failure.
        #expect(runner.calls.contains { $0.prefix(2) == ["/usr/bin/hdiutil", "detach"] })
    }

    @Test func refusesVersionThatDoesNotMatchRelease() throws {
        let temp = try TempDirectory()
        try temp.fakeApp("Volume/OpenClean.app", version: "0.2.9")
        let runner = ScriptedRunner(mountPoint: temp.path + "/Volume")
        #expect(throws: UpdateError.self) {
            try UpdateInstaller(runner: runner, bundleIdentifier: Self.bundleID).stage(verified(temp))
        }
    }

    @Test func refusesBadSignature() throws {
        let temp = try TempDirectory()
        try temp.fakeApp("Volume/OpenClean.app", version: "0.3.0")
        let runner = ScriptedRunner(mountPoint: temp.path + "/Volume")
        runner.codesignStatus = 1
        #expect(throws: UpdateError.signatureInvalid("a sealed resource is missing")) {
            try UpdateInstaller(runner: runner, bundleIdentifier: Self.bundleID).stage(verified(temp))
        }
    }

    @Test func refusesSymlinkedAppOnImage() throws {
        let temp = try TempDirectory()
        let real = try temp.fakeApp("Elsewhere/OpenClean.app", version: "0.3.0")
        try temp.directory("Volume")
        try temp.symlink("Volume/OpenClean.app", to: real)
        let runner = ScriptedRunner(mountPoint: temp.path + "/Volume")
        #expect(throws: UpdateError.self) {
            try UpdateInstaller(runner: runner, bundleIdentifier: Self.bundleID).stage(verified(temp))
        }
        #expect(!runner.calls.contains { $0.first == "/usr/bin/ditto" })
    }

    @Test func attachFailureIsReported() throws {
        let temp = try TempDirectory()
        let runner = ScriptedRunner(mountPoint: temp.path + "/Volume")
        runner.attachStatus = 1
        #expect(throws: UpdateError.self) {
            try UpdateInstaller(runner: runner, bundleIdentifier: Self.bundleID).stage(verified(temp))
        }
    }

    @Test func mountPointParsingRejectsRelativePaths() throws {
        let plist: [String: Any] = [
            "system-entities": [["mount-point": "Volumes/x"], ["mount-point": "/Volumes/../x"]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(UpdateInstaller.mountPoint(fromAttachPlist: data) == nil)
        #expect(UpdateInstaller.mountPoint(fromAttachPlist: Data("junk".utf8)) == nil)
    }
}

struct UpdateSettingsTests {
    func defaults() -> UserDefaults {
        let name = "openclean-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func autoCheckIsOnByDefault() {
        let store = UpdateSettingsStore(defaults: defaults())
        #expect(store.autoCheck)
        store.autoCheck = false
        #expect(!store.autoCheck)
    }

    @Test func persistsSkippedVersionAndLastCheck() {
        let defaults = defaults()
        let store = UpdateSettingsStore(defaults: defaults)
        store.skippedVersion = SemanticVersion("0.3.0")
        store.lastCheck = Date(timeIntervalSince1970: 100)
        let reloaded = UpdateSettingsStore(defaults: defaults)
        #expect(reloaded.skippedVersion == SemanticVersion("0.3.0"))
        #expect(reloaded.lastCheck == Date(timeIntervalSince1970: 100))
    }

    @Test func relaunchRecordIsConsumedOnce() {
        let store = UpdateSettingsStore(defaults: defaults())
        store.recordRelaunch(from: SemanticVersion("0.2.0"), to: SemanticVersion("0.3.0")!)
        #expect(store.consumeRelaunch(current: SemanticVersion("0.3.0")) == SemanticVersion("0.2.0"))
        #expect(store.consumeRelaunch(current: SemanticVersion("0.3.0")) == nil)

        // A launch of some other version just forgets it.
        store.recordRelaunch(from: SemanticVersion("0.2.0"), to: SemanticVersion("0.3.0")!)
        #expect(store.consumeRelaunch(current: SemanticVersion("0.2.0")) == nil)
        #expect(store.consumeRelaunch(current: SemanticVersion("0.3.0")) == nil)
    }
}
