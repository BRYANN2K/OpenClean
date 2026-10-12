import Foundation
import OpenCleanKit
import Quarantine
import RuleKit
import ScanEngine
import TestSupport
import Testing
import Updater

struct CoordinatorUpdatesTests {
    static let bundleID = "com.openclean"

    func coordinator(_ home: TempDirectory, environment: [String: String] = [:]) -> OpenCleanCoordinator {
        OpenCleanCoordinator(
            home: home.path, environment: environment, registry: ProbeRegistry([]),
            processChecker: FakeProcessChecker(), openFiles: FakeOpenFiles(), admin: FakeAdminExecutor(),
            fullDiskAccess: { .granted }, trash: { _ in nil })
    }

    func release(_ client: FakeHTTPClient, dmg: Data, checksum: String? = nil) -> Release {
        let dmgURL = URL(
            string: "https://github.com/leoAnimesh/OpenClean/releases/download/v0.3.0/OpenClean-0.3.0.dmg")!
        let sumsURL = URL(string: "https://github.com/leoAnimesh/OpenClean/releases/download/v0.3.0/SHA256SUMS.txt")!
        client.respond(dmgURL, body: dmg)
        let digest =
            try! checksum
            ?? {
                let temp = try TempDirectory()
                let path = try temp.file("d")
                try dmg.write(to: URL(fileURLWithPath: path))
                return try UpdateDownloader.sha256(of: path)
            }()
        client.respond(sumsURL, text: "\(digest)  OpenClean-0.3.0.dmg\n")
        return Release(
            version: SemanticVersion("0.3.0")!, tagName: "v0.3.0", name: "", notes: "",
            htmlURL: ReleaseFeed.releasesPage, publishedAt: nil,
            assets: [
                ReleaseAsset(name: "OpenClean-0.3.0.dmg", downloadURL: dmgURL, size: Int64(dmg.count)),
                ReleaseAsset(name: "SHA256SUMS.txt", downloadURL: sumsURL, size: 80),
            ])
    }

    @Test func updatesLiveInSupportFolderUnderOverriddenHome() throws {
        let home = try TempDirectory()
        let coordinator = coordinator(home)
        #expect(coordinator.updatesDirectory.path == home.path + "/Library/Application Support/OpenClean/Updates")
        #expect(coordinator.updateFeedURL == ReleaseFeed.defaultURL)
        #expect(!coordinator.updateHostPolicy.allowsFileURLs)

        let dev = self.coordinator(home, environment: ["OPENCLEAN_UPDATE_FEED": "/tmp/feed.json"])
        #expect(dev.updateFeedURL.isFileURL)
        #expect(dev.updateHostPolicy.allowsFileURLs)
    }

    @Test func downloadReplacesAnEarlierAttempt() async throws {
        let home = try TempDirectory()
        let coordinator = coordinator(home)
        let stale = try home.file("Library/Application Support/OpenClean/Updates/0.3.0/OpenClean-0.3.0.dmg", bytes: 2)
        let client = FakeHTTPClient()
        let download = try await coordinator.downloadUpdate(
            release(client, dmg: Data(repeating: 7, count: 100)), client: client, appVersion: "0.2.0")
        #expect(download.dmgPath == stale)
        #expect(try Data(contentsOf: URL(fileURLWithPath: stale)).count == 100)
    }

    @Test func failedDownloadIsCleared() async throws {
        let home = try TempDirectory()
        let coordinator = coordinator(home)
        let client = FakeHTTPClient()
        let bad = release(client, dmg: Data(repeating: 7, count: 100), checksum: String(repeating: "0", count: 64))
        await #expect(throws: UpdateError.checksumMismatch("OpenClean-0.3.0.dmg")) {
            try await coordinator.downloadUpdate(bad, client: client, appVersion: "0.2.0")
        }
        #expect(FileStat.of(coordinator.updatesDirectory.path + "/0.3.0") == nil)
    }

    @Test func installerSwapsAppAndClearsUpdates() throws {
        let home = try TempDirectory()
        let coordinator = coordinator(home)
        let current = try home.fakeApp("Applications/OpenClean.app", version: "0.2.0")
        let staged = try home.fakeApp(
            "Library/Application Support/OpenClean/Updates/0.3.0/staged-x/OpenClean.app", version: "0.3.0")
        let dmg = try home.file("Library/Application Support/OpenClean/Updates/0.3.0/OpenClean-0.3.0.dmg", bytes: 1)
        let installer = coordinator.selfUpdateInstaller(
            bundleIdentifier: Self.bundleID, runner: FakeCommandRunner(), runningTeamIdentifier: nil)
        #expect(installer.installBlocker(currentApp: current) == nil)

        let rel = Release(
            version: SemanticVersion("0.3.0")!, tagName: "v0.3.0", name: "", notes: "",
            htmlURL: ReleaseFeed.releasesPage, publishedAt: nil, assets: [])
        try installer.install(StagedUpdate(release: rel, appPath: staged, dmgPath: dmg), currentApp: current)

        #expect(UpdateInstaller.bundleInfo(current)?.version == "0.3.0")
        #expect(FileStat.of(coordinator.updatesDirectory.path + "/0.3.0") == nil)
        let sessions = coordinator.history()
        guard case .ok(let manifest) = try #require(sessions.first) else {
            Issue.record("no readable session")
            return
        }
        #expect(manifest.entries.first?.ruleID == SelfUpdateReplacer.ruleID)
        #expect(manifest.restorableEntries.count == 1)

        let report = try coordinator.restore(sessionID: manifest.id, onConflict: .keepBoth)
        #expect(report.restored == [home.path + "/Applications/OpenClean (restored).app"])
        #expect(UpdateInstaller.bundleInfo(report.restored[0])?.version == "0.2.0")
    }

    @Test func installerExplainsWhyItCannotReplace() throws {
        let home = try TempDirectory()
        let coordinator = coordinator(home)
        let installer = coordinator.selfUpdateInstaller(
            bundleIdentifier: Self.bundleID, runner: FakeCommandRunner(), runningTeamIdentifier: nil)
        let translocated = try home.fakeApp("AppTranslocation/X/d/OpenClean.app")
        #expect(installer.installBlocker(currentApp: translocated)?.contains("Applications folder") == true)
        try home.file("Repo/Package.swift")
        let dev = try home.fakeApp("Repo/build/OpenClean.app")
        #expect(installer.installBlocker(currentApp: dev)?.contains("development build") == true)
        #expect(installer.installBlocker(currentApp: home.path + "/.build/debug") != nil)
    }
}
