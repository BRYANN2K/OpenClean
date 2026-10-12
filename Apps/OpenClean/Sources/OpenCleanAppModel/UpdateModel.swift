import Foundation
import Observation
import OpenCleanKit
import Quarantine
import Updater

/// Software Update: checks GitHub for a newer release, downloads and verifies it, stages it, and swaps
/// it in. Views call its actions; the filesystem work happens in `UpdateInstalling` and the coordinator.
///
/// Scheduling: when `autoCheck` is on (the default), `onLaunch` checks if the last successful check
/// was more than `checkInterval` (24 h) ago, then again every `checkInterval` while the app runs.
/// When it's off there is no timer at all. Manual checks (`checkForUpdates`) always work.
@MainActor
@Observable
public final class UpdateModel {
    public enum State: Equatable {
        case idle
        case checking
        case upToDate(checkedAt: Date)
        case available(Release)
        case downloading(DownloadProgress)
        case verifying
        case ready(StagedUpdate)
        case installing
        case failed(String)
    }

    public private(set) var state: State = .idle
    public var isSheetPresented = false
    /// The newest release found that is newer than this version.
    public private(set) var release: Release?
    public private(set) var lastChecked: Date?
    public private(set) var skippedVersion: SemanticVersion?
    /// "Remind Me Later": hides the banner until the next launch.
    public private(set) var remindLater = false
    /// Why the running copy can't be replaced in place (translocated, read-only, development build…);
    /// nil when it can. Set once an update is staged.
    public private(set) var installBlocker: String?
    /// Set on the first launch after an in-app update: the version it came from.
    public private(set) var updatedFrom: SemanticVersion?
    public let currentVersion: SemanticVersion?
    public let currentVersionText: String

    public var autoCheck: Bool {
        didSet {
            guard autoCheck != oldValue else { return }
            settings.autoCheck = autoCheck
            reschedule()
        }
    }

    @ObservationIgnored private let coordinator: OpenCleanCoordinator
    @ObservationIgnored private let settings: UpdateSettingsStore
    @ObservationIgnored private let client: any HTTPClient
    @ObservationIgnored private let installer: any UpdateInstalling
    @ObservationIgnored private let currentAppPath: String
    @ObservationIgnored private let checkInterval: TimeInterval
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let relaunch: @MainActor (String) -> Void
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored private var workTask: Task<Void, Never>?
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var launched = false

    public init(
        coordinator: OpenCleanCoordinator, settings: UpdateSettingsStore, client: any HTTPClient,
        installer: any UpdateInstalling, currentVersion: String?, currentAppPath: String,
        checkInterval: TimeInterval = 24 * 60 * 60, now: @escaping @Sendable () -> Date = { Date() },
        relaunch: @escaping @MainActor (String) -> Void
    ) {
        self.coordinator = coordinator
        self.settings = settings
        self.client = client
        self.installer = installer
        currentVersionText = currentVersion ?? "unknown"
        self.currentVersion = currentVersion.flatMap(SemanticVersion.init)
        self.currentAppPath = currentAppPath
        self.checkInterval = checkInterval
        self.now = now
        self.relaunch = relaunch
        autoCheck = settings.autoCheck
        lastChecked = settings.lastCheck
        skippedVersion = settings.skippedVersion
    }

    // MARK: Lifecycle

    /// Safe to call more than once (each new main window runs it); only the first call acts.
    public func onLaunch() {
        guard !launched else { return }
        launched = true
        updatedFrom = settings.consumeRelaunch(current: currentVersion)
        // Nothing is in flight at launch, so any earlier download or staging folder is stale.
        let coordinator = coordinator
        Task.detached(priority: .utility) { coordinator.cleanUpUpdates() }
        reschedule()
    }

    /// True while an automatic check timer is running (tests).
    public var isScheduled: Bool { scheduleTask != nil }

    private func reschedule() {
        scheduleTask?.cancel()
        scheduleTask = nil
        guard autoCheck else { return }
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                // No strong reference is held while sleeping.
                guard let delay = self?.nextCheckDelay() else { return }
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
                guard !Task.isCancelled, let model = self, model.autoCheck else { return }
                await model.check(userInitiated: false)
            }
        }
    }

    /// Seconds until the next automatic check: `checkInterval` after the last check or attempt.
    private func nextCheckDelay() -> TimeInterval {
        let reference = [lastChecked, lastAttempt].compactMap { $0 }.max() ?? .distantPast
        return reference.addingTimeInterval(checkInterval).timeIntervalSince(now())
    }

    /// Stops the automatic-check timer (tests; the app lives until quit).
    public func stop() {
        scheduleTask?.cancel()
        scheduleTask = nil
        workTask?.cancel()
    }

    // MARK: Banner

    /// The release the banner announces, or nil (none found, skipped, or "Remind Me Later").
    public var bannerRelease: Release? {
        guard let release, !remindLater, release.version != skippedVersion else { return nil }
        return release
    }

    public func showUpdate() {
        if let release, state == .idle || isFinishedState { state = .available(release) }
        isSheetPresented = true
    }

    private var isFinishedState: Bool {
        switch state {
        case .upToDate, .failed: true
        default: false
        }
    }

    private var isBusy: Bool {
        switch state {
        case .downloading, .verifying, .ready, .installing: true
        default: false
        }
    }

    // MARK: Checking

    /// OpenClean → Check for Updates… and Settings → Check Now: shows the sheet and its result.
    public func checkForUpdates() {
        isSheetPresented = true
        guard !isBusy, state != .checking else { return }
        state = .checking
        workTask = Task { await self.check(userInitiated: true) }
    }

    /// Waits for the current check, download or install (tests).
    public func waitForWork() async {
        await workTask?.value
    }

    func check(userInitiated: Bool) async {
        // Recorded even when skipped below, so the automatic timer always waits a full interval.
        lastAttempt = now()
        if isBusy || (state == .checking && !userInitiated) { return }
        if userInitiated { state = .checking }
        do {
            let latest = try await coordinator.checkForUpdate(client: client, appVersion: currentVersionText)
            let checkedAt = now()
            lastChecked = checkedAt
            settings.lastCheck = checkedAt
            if isBusy { return }
            if isNewer(latest) {
                release = latest
                if userInitiated || latest.version != skippedVersion { state = .available(latest) }
            } else {
                release = nil
                if userInitiated || state == .idle || isFinishedState { state = .upToDate(checkedAt: checkedAt) }
            }
        } catch {
            if userInitiated, !isBusy { state = .failed(Self.describe(error)) }
        }
    }

    private func isNewer(_ release: Release) -> Bool {
        guard !release.version.isPrerelease else { return false }
        return release.version > (currentVersion ?? SemanticVersion(major: 0, minor: 0, patch: 0))
    }

    // MARK: Choices

    public func skipThisVersion() {
        guard let release else { return }
        skippedVersion = release.version
        settings.skippedVersion = release.version
        isSheetPresented = false
        if case .available = state { state = .idle }
    }

    public func remindMeLater() {
        remindLater = true
        isSheetPresented = false
    }

    // MARK: Download, verify, stage

    public func downloadAndInstall() {
        guard let release, release.isInstallable, !isBusy else { return }
        state = .downloading(DownloadProgress(received: 0, total: release.dmg?.size, bytesPerSecond: 0))
        installBlocker = nil
        let coordinator = coordinator
        let client = client
        let installer = installer
        let appVersion = currentVersionText
        let currentApp = currentAppPath
        workTask = Task {
            let (stream, continuation) = AsyncStream.makeStream(of: DownloadProgress.self)
            async let downloaded = coordinator.downloadUpdate(
                release, client: client, appVersion: appVersion, progress: continuation)
            for await progress in stream where self.isDownloading {
                if let total = progress.total, progress.received >= total {
                    self.state = .verifying
                } else {
                    self.state = .downloading(progress)
                }
            }
            do {
                let download = try await downloaded
                try Task.checkCancellation()
                self.state = .verifying
                let staged = try await Task.detached { try installer.stage(download) }.value
                let blocker = await Task.detached { installer.installBlocker(currentApp: currentApp) }.value
                try Task.checkCancellation()
                self.installBlocker = blocker
                self.state = .ready(staged)
            } catch is CancellationError {
                self.state = .available(release)
            } catch {
                self.state = .failed(Self.describe(error))
            }
        }
    }

    private var isDownloading: Bool {
        switch state {
        case .downloading, .verifying: true
        default: false
        }
    }

    public func cancelDownload() {
        guard isDownloading else { return }
        workTask?.cancel()
    }

    /// Retry after a failure: download again if a release is known, otherwise check again.
    public func retry() {
        if let release, release.isInstallable {
            state = .available(release)
            downloadAndInstall()
        } else {
            state = .idle
            checkForUpdates()
        }
    }

    // MARK: Install

    /// The verified disk image, for "Open Installer" when an in-place install isn't possible.
    public var stagedDiskImage: URL? {
        guard case .ready(let staged) = state else { return nil }
        return URL(fileURLWithPath: staged.dmgPath)
    }

    public func installAndRelaunch() {
        guard case .ready(let staged) = state, installBlocker == nil else { return }
        state = .installing
        let installer = installer
        let currentApp = currentAppPath
        workTask = Task {
            do {
                try await Task.detached { try installer.install(staged, currentApp: currentApp) }.value
                self.settings.recordRelaunch(from: self.currentVersion, to: staged.version)
                self.relaunch(currentApp)
            } catch {
                self.state = .failed(Self.describe(error))
            }
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as UpdateError: error.description
        case let error as SelfUpdateError: "Couldn't install the update: \(error.description)."
        case let error as URLError:
            "OpenClean couldn't reach GitHub (\(error.localizedDescription)). Check your connection and try again."
        default: error.localizedDescription
        }
    }
}
