import Foundation
import Testing
import TestSupport
@testable import Permissions

struct PermissionsTests {
    @Test func grantedWhenProtectedFolderIsReadable() throws {
        let home = try TempDirectory()
        try home.file("Library/Safari/Bookmarks.plist", bytes: 1)
        #expect(FullDiskAccessChecker(home: home.path).status() == .granted)
    }

    @Test func deniedWhenProtectedFolderIsUnreadable() throws {
        let home = try TempDirectory()
        let safari = try home.directory("Library/Safari")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: safari)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: safari) }
        #expect(FullDiskAccessChecker(home: home.path).status() == .denied)
    }

    @Test func unknownWhenNoProbeFolderExists() throws {
        let home = try TempDirectory()
        #expect(FullDiskAccessChecker(home: home.path).status() == .unknown)
    }

    @Test func adviceTracksGrantsAcrossRebuilds() {
        let suite = "openclean.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(SignatureTracker(defaults: defaults, currentSignature: "aaa").advise(status: .denied) == .grant)
        #expect(SignatureTracker(defaults: defaults, currentSignature: "aaa").advise(status: .granted) == .ok)
        #expect(SignatureTracker(defaults: defaults, currentSignature: "aaa").advise(status: .denied) == .grant)
        #expect(
            SignatureTracker(defaults: defaults, currentSignature: "bbb").advise(status: .denied)
                == .regrantAfterRebuild)
        #expect(SignatureTracker(defaults: defaults, currentSignature: "bbb").advise(status: .granted) == .ok)
    }

    @Test func settingsURLOpensFullDiskAccessPane() {
        #expect(FullDiskAccessChecker.settingsURL.absoluteString.hasSuffix("Privacy_AllFiles"))
    }

    @Test func currentSignatureLookupDoesNotCrash() {
        _ = SignatureTracker.currentCDHash()
    }
}
