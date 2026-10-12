import CryptoKit
import Foundation
import OpenCleanKit
import ScanEngine
import TestSupport
import Testing
import Updater

@testable import OpenCleanAppModel

/// Records calls; never touches an app. `stage` fabricates a staged path, `install` does nothing.
final class FakeUpdateInstaller: UpdateInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var staged: [VerifiedDownload] = []
    private var installed: [(StagedUpdate, String)] = []
    var blocker: String?
    var stageError: (any Error)?
    var installError: (any Error)?

    var stagedDownloads: [VerifiedDownload] { lock.withLock { staged } }
    var installs: [(StagedUpdate, String)] { lock.withLock { installed } }

    func stage(_ download: VerifiedDownload) throws -> StagedUpdate {
        try lock.withLock {
            staged.append(download)
            if let stageError { throw stageError }
            return StagedUpdate(
                release: download.release, appPath: download.dmgPath + ".staged/OpenClean.app",
                dmgPath: download.dmgPath)
        }
    }

    func installBlocker(currentApp: String) -> String? { lock.withLock { blocker } }

    func install(_ staged: StagedUpdate, currentApp: String) throws {
        try lock.withLock {
            installed.append((staged, currentApp))
            if let installError { throw installError }
        }
    }
}

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

@MainActor
struct UpdateModelTests {
    static let dmgBytes = Data(repeating: 0x5A, count: 2048)
    static let dmgURL = URL(
        string: "https://github.com/leoAnimesh/OpenClean/releases/download/v0.3.0/OpenClean-0.3.0.dmg")!
    static let sumsURL = URL(string: "https://github.com/leoAnimesh/OpenClean/releases/download/v0.3.0/SHA256SUMS.txt")!

    struct Harness {
        let home: TempDirectory
        let client: FakeHTTPClient
        let installer: FakeUpdateInstaller
        let defaults: UserDefaults
        let clock: TestClock
        let relaunched: Box
        let model: UpdateModel
    }

    final class Box: @unchecked Sendable {
        var paths: [String] = []
    }

    func harness(
        version: String = "0.2.0", latest: String? = "v0.3.0", autoCheck: Bool? = nil, lastCheck: Date? = nil,
        interval: TimeInterval = 24 * 60 * 60, defaults: UserDefaults? = nil,
        cleanUp: (@Sendable (OpenCleanCoordinator) -> Void)? = nil
    ) throws -> Harness {
        let home = try TempDirectory()
        let coordinator = OpenCleanCoordinator(
            home: home.path, environment: [:], registry: ProbeRegistry([]), processChecker: FakeProcessChecker(),
            openFiles: FakeOpenFiles(), admin: FakeAdminExecutor(), fullDiskAccess: { .granted }, trash: { _ in nil })
        let client = FakeHTTPClient()
        if let latest {
            client.respond(
                ReleaseFeed.defaultURL,
                body: releaseJSON(
                    tag: latest,
                    assets: [
                        ("OpenClean-0.3.0.dmg", Self.dmgURL.absoluteString, Self.dmgBytes.count),
                        ("SHA256SUMS.txt", Self.sumsURL.absoluteString, 100),
                    ]))
        }
        client.respond(Self.dmgURL, body: Self.dmgBytes)
        let digest = SHA256.hash(data: Self.dmgBytes).map { String(format: "%02x", $0) }.joined()
        client.respond(Self.sumsURL, text: "\(digest)  OpenClean-0.3.0.dmg\n")

        let suite = defaults ?? Self.freshDefaults()
        let settings = UpdateSettingsStore(defaults: suite)
        if let autoCheck { settings.autoCheck = autoCheck }
        if let lastCheck { settings.lastCheck = lastCheck }
        let installer = FakeUpdateInstaller()
        let clock = TestClock()
        let relaunched = Box()
        var cleanUpUpdates: (@Sendable () -> Void)?
        if let cleanUp { cleanUpUpdates = { @Sendable in cleanUp(coordinator) } }
        let model = UpdateModel(
            coordinator: coordinator, settings: settings, client: client, installer: installer,
            currentVersion: version, currentAppPath: "/Applications/OpenClean.app", checkInterval: interval,
            now: { clock.now }, relaunch: { relaunched.paths.append($0) },
            cleanUpUpdates: cleanUpUpdates)
        return Harness(
            home: home, client: client, installer: installer, defaults: suite, clock: clock, relaunched: relaunched,
            model: model)
    }

    static func freshDefaults() -> UserDefaults {
        let name = "openclean-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    var feedRequests: (FakeHTTPClient) -> Int {
        { client in client.requests.filter { $0.url == ReleaseFeed.defaultURL }.count }
    }

    // MARK: Checking

    @Test func manualCheckFindsUpdate() async throws {
        let h = try harness(autoCheck: false)
        h.model.checkForUpdates()
        #expect(h.model.isSheetPresented)
        #expect(h.model.state == .checking)
        await h.model.waitForWork()
        guard case .available(let release) = h.model.state else {
            Issue.record("expected available, got \(h.model.state)")
            return
        }
        #expect(release.version == SemanticVersion("0.3.0"))
        #expect(h.model.bannerRelease?.version == SemanticVersion("0.3.0"))
        #expect(h.model.lastChecked == h.clock.now)
    }

    @Test func manualCheckWhenUpToDate() async throws {
        let h = try harness(version: "0.3.0", autoCheck: false)
        h.model.checkForUpdates()
        await h.model.waitForWork()
        #expect(h.model.state == .upToDate(checkedAt: h.clock.now))
        #expect(h.model.bannerRelease == nil)
    }

    @Test func olderOrPrereleaseIsNotAnUpdate() async throws {
        let h = try harness(version: "0.4.0", autoCheck: false)
        h.model.checkForUpdates()
        await h.model.waitForWork()
        #expect(h.model.state == .upToDate(checkedAt: h.clock.now))
    }

    @Test func offlineOrMissingFeedFails() async throws {
        let h = try harness(latest: nil, autoCheck: false)
        h.model.checkForUpdates()
        await h.model.waitForWork()
        guard case .failed(let message) = h.model.state else {
            Issue.record("expected failure, got \(h.model.state)")
            return
        }
        #expect(message.contains("No OpenClean release"))
        #expect(h.model.lastChecked == nil)
    }

    // MARK: Scheduling

    @Test func autoCheckIsOnByDefaultAndChecksAtLaunch() async throws {
        let h = try harness()
        #expect(h.model.autoCheck)
        h.model.onLaunch()
        defer { h.model.stop() }
        try await waitUntil { h.model.lastChecked != nil }
        #expect(feedRequests(h.client) == 1)
        // Silent: the banner appears but the sheet doesn't open.
        #expect(!h.model.isSheetPresented)
        #expect(h.model.bannerRelease?.version == SemanticVersion("0.3.0"))
        #expect(h.model.isScheduled)
    }

    @Test func noLaunchCheckWhenCheckedRecently() async throws {
        let clockStart = TestClock().now
        let h = try harness(autoCheck: true, lastCheck: clockStart.addingTimeInterval(-3600))
        h.model.onLaunch()
        defer { h.model.stop() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(feedRequests(h.client) == 0)
        #expect(h.model.isScheduled)
    }

    @Test func checksAgainEveryInterval() async throws {
        let h = try harness(autoCheck: true, interval: 0.05)
        h.model.onLaunch()
        defer { h.model.stop() }
        try await waitUntil { feedRequests(h.client) >= 1 }
        // The fake clock doesn't move, so the next check comes once it's advanced past the interval.
        h.clock.advance(1)
        try await waitUntil { feedRequests(h.client) >= 2 }
        #expect(feedRequests(h.client) >= 2)
    }

    @Test func noTimerAndNoRequestsWhenAutoCheckOff() async throws {
        let h = try harness(autoCheck: false)
        h.model.onLaunch()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!h.model.isScheduled)
        #expect(h.client.requests.isEmpty)

        h.model.autoCheck = true
        defer { h.model.stop() }
        #expect(h.model.isScheduled)
        try await waitUntil { feedRequests(h.client) == 1 }
        #expect(UpdateSettingsStore(defaults: h.defaults).autoCheck)

        h.model.autoCheck = false
        #expect(!h.model.isScheduled)
        #expect(!UpdateSettingsStore(defaults: h.defaults).autoCheck)
    }

    // MARK: Choices

    @Test func skipThisVersionPersistsAndHidesBanner() async throws {
        let defaults = Self.freshDefaults()
        let h = try harness(autoCheck: false, defaults: defaults)
        h.model.checkForUpdates()
        await h.model.waitForWork()
        h.model.skipThisVersion()
        #expect(h.model.bannerRelease == nil)
        #expect(!h.model.isSheetPresented)

        // A fresh launch with automatic checks doesn't announce the skipped version…
        let next = try harness(autoCheck: true, lastCheck: .distantPast, defaults: defaults)
        next.model.onLaunch()
        defer { next.model.stop() }
        try await waitUntil { next.model.release != nil }
        #expect(next.model.skippedVersion == SemanticVersion("0.3.0"))
        #expect(next.model.bannerRelease == nil)
        #expect(next.model.release?.version == SemanticVersion("0.3.0"))
        #expect(!next.model.isSheetPresented)

        // …but a manual check still shows it.
        next.model.checkForUpdates()
        await next.model.waitForWork()
        guard case .available = next.model.state else {
            Issue.record("manual check should show the skipped version")
            return
        }
    }

    @Test func remindMeLaterHidesBannerForThisLaunch() async throws {
        let h = try harness(autoCheck: false)
        h.model.checkForUpdates()
        await h.model.waitForWork()
        h.model.remindMeLater()
        #expect(h.model.bannerRelease == nil)
        #expect(!h.model.isSheetPresented)
        #expect(UpdateSettingsStore(defaults: h.defaults).skippedVersion == nil)
    }

    // MARK: Download and install

    @Test func downloadVerifiesAndStages() async throws {
        let h = try harness(autoCheck: false)
        h.model.checkForUpdates()
        await h.model.waitForWork()
        h.model.downloadAndInstall()
        await h.model.waitForWork()
        guard case .ready(let staged) = h.model.state else {
            Issue.record("expected ready, got \(h.model.state)")
            return
        }
        #expect(staged.version == SemanticVersion("0.3.0"))
        #expect(h.model.installBlocker == nil)
        let download = try #require(h.installer.stagedDownloads.first)
        #expect(download.dmgPath.hasPrefix(h.home.path + "/Library/Application Support/OpenClean/Updates/0.3.0/"))
        #expect(h.model.stagedDiskImage?.path == download.dmgPath)
    }

    @Test func downloadWaitsForTheLaunchCleanup() async throws {
        let client = Box2()
        let dmgURL = Self.dmgURL
        let h = try harness(autoCheck: false) { coordinator in
            // A slow cleanup: a download started meanwhile must not touch the Updates folder yet.
            Thread.sleep(forTimeInterval: 0.3)
            client.dmgRequestedDuringCleanup =
                client.client?.requests.contains { $0.url == dmgURL } ?? false
            coordinator.cleanUpUpdates()
        }
        client.client = h.client
        let updates = h.home.path + "/Library/Application Support/OpenClean/Updates"
        try FileManager.default.createDirectory(atPath: updates + "/0.1.0", withIntermediateDirectories: true)
        h.model.checkForUpdates()
        await h.model.waitForWork()
        h.model.onLaunch()
        h.model.downloadAndInstall()
        await h.model.waitForWork()
        guard case .ready(let staged) = h.model.state else {
            Issue.record("expected ready, got \(h.model.state)")
            return
        }
        #expect(client.dmgRequestedDuringCleanup == false)
        #expect(!FileManager.default.fileExists(atPath: updates + "/0.1.0"))
        #expect(FileManager.default.fileExists(atPath: staged.dmgPath))
    }

    final class Box2: @unchecked Sendable {
        var client: FakeHTTPClient?
        var dmgRequestedDuringCleanup: Bool?
    }

    @Test func installRelaunchesAndRecordsTheHandOver() async throws {
        let h = try harness(autoCheck: false)
        h.model.checkForUpdates()
        await h.model.waitForWork()
        h.model.downloadAndInstall()
        await h.model.waitForWork()
        h.model.installAndRelaunch()
        #expect(h.model.state == .installing)
        await h.model.waitForWork()
        #expect(h.installer.installs.count == 1)
        #expect(h.installer.installs.first?.1 == "/Applications/OpenClean.app")
        #expect(h.relaunched.paths == ["/Applications/OpenClean.app"])

        // The next launch (now 0.3.0) knows it was just updated.
        let next = try harness(version: "0.3.0", autoCheck: false, defaults: h.defaults)
        next.model.onLaunch()
        #expect(next.model.updatedFrom == SemanticVersion("0.2.0"))
    }

    @Test func blockedInstallOffersInstallerInstead() async throws {
        let h = try harness(autoCheck: false)
        h.installer.blocker = "This is a development build."
        h.model.checkForUpdates()
        await h.model.waitForWork()
        h.model.downloadAndInstall()
        await h.model.waitForWork()
        #expect(h.model.installBlocker == "This is a development build.")
        h.model.installAndRelaunch()
        await h.model.waitForWork()
        #expect(h.installer.installs.isEmpty)
        #expect(h.relaunched.paths.isEmpty)
        #expect(h.model.stagedDiskImage != nil)
    }

    @Test func installFailureIsShownAndNothingRelaunches() async throws {
        let h = try harness(autoCheck: false)
        h.installer.installError = UpdateError.stagingFailed("disk full")
        h.model.checkForUpdates()
        await h.model.waitForWork()
        h.model.downloadAndInstall()
        await h.model.waitForWork()
        h.model.installAndRelaunch()
        await h.model.waitForWork()
        guard case .failed(let message) = h.model.state else {
            Issue.record("expected failure")
            return
        }
        #expect(message.contains("disk full"))
        #expect(h.relaunched.paths.isEmpty)
    }

    @Test func checksumFailureIsShownAndRetryWorks() async throws {
        let h = try harness(autoCheck: false)
        h.client.respond(Self.sumsURL, text: "\(String(repeating: "0", count: 64))  OpenClean-0.3.0.dmg\n")
        h.model.checkForUpdates()
        await h.model.waitForWork()
        h.model.downloadAndInstall()
        await h.model.waitForWork()
        guard case .failed(let message) = h.model.state else {
            Issue.record("expected failure, got \(h.model.state)")
            return
        }
        #expect(message.contains("checksum"))
        #expect(h.installer.stagedDownloads.isEmpty)

        let digest = SHA256.hash(data: Self.dmgBytes).map { String(format: "%02x", $0) }.joined()
        h.client.respond(Self.sumsURL, text: "\(digest)  OpenClean-0.3.0.dmg\n")
        h.model.retry()
        await h.model.waitForWork()
        guard case .ready = h.model.state else {
            Issue.record("expected ready after retry, got \(h.model.state)")
            return
        }
    }

    @Test func cancelReturnsToAvailable() async throws {
        let h = try harness(autoCheck: false)
        h.client.respond(Self.dmgURL, body: Self.dmgBytes, delay: .seconds(30))
        h.model.checkForUpdates()
        await h.model.waitForWork()
        h.model.downloadAndInstall()
        guard case .downloading = h.model.state else {
            Issue.record("expected downloading")
            return
        }
        try await Task.sleep(for: .milliseconds(50))
        h.model.cancelDownload()
        await h.model.waitForWork()
        guard case .available = h.model.state else {
            Issue.record("expected available after cancel, got \(h.model.state)")
            return
        }
        #expect(h.installer.stagedDownloads.isEmpty)
    }

    @Test func notInstallableReleaseCannotBeDownloaded() async throws {
        let h = try harness(autoCheck: false)
        h.client.respond(ReleaseFeed.defaultURL, body: releaseJSON(tag: "v0.3.0", assets: []))
        h.model.checkForUpdates()
        await h.model.waitForWork()
        #expect(h.model.release?.isInstallable == false)
        h.model.downloadAndInstall()
        guard case .available = h.model.state else {
            Issue.record("should stay available")
            return
        }
    }
}
