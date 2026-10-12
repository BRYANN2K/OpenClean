import Foundation
import ProcessKit
import Quarantine
import Updater

/// Software Update wiring. Downloads and staging folders live in `<support>/Updates/` (honours
/// `OPENCLEAN_HOME`); the previous version goes to the coordinator's quarantine store; the feed URL and
/// host policy come from the environment (`OPENCLEAN_UPDATE_FEED`). Update preferences (auto-check,
/// last check, skipped version) are in `UserDefaults` via `UpdateSettingsStore`, not `settings.json`.
extension OpenCleanCoordinator {
    public var updatesDirectory: URL { paths.support.appendingPathComponent("Updates", isDirectory: true) }

    public var updateStagingCleaner: UpdateStagingCleaner { UpdateStagingCleaner(updatesDirectory: updatesDirectory) }

    /// The real network client, restricted to the update host allowlist.
    public func makeUpdateHTTPClient() -> any HTTPClient { URLSessionHTTPClient(policy: updateHostPolicy) }

    public func releaseFeed(client: any HTTPClient, appVersion: String) -> ReleaseFeed {
        ReleaseFeed(client: client, appVersion: appVersion, url: updateFeedURL, policy: updateHostPolicy)
    }

    public func checkForUpdate(client: any HTTPClient, appVersion: String) async throws -> Release {
        try await releaseFeed(client: client, appVersion: appVersion).latest()
    }

    /// Clears any earlier attempt for this version, then downloads and verifies the disk image. On
    /// failure or cancellation the partial download is cleared again.
    public func downloadUpdate(
        _ release: Release, client: any HTTPClient, appVersion: String,
        progress: AsyncStream<DownloadProgress>.Continuation? = nil
    ) async throws -> VerifiedDownload {
        let cleaner = updateStagingCleaner
        try? cleaner.remove(release.version.core)
        let downloader = UpdateDownloader(
            client: client, policy: updateHostPolicy, updatesDirectory: updatesDirectory, appVersion: appVersion)
        do {
            return try await downloader.download(release, progress: progress)
        } catch {
            try? cleaner.remove(release.version.core)
            throw error
        }
    }

    /// Removes leftover downloads and staging folders (call at launch, when nothing is in flight).
    @discardableResult
    public func cleanUpUpdates(keeping: String? = nil) -> [String] {
        updateStagingCleaner.removeAll(keeping: keeping)
    }

    /// `runningTeamIdentifier` is the running app's Developer ID team (nil when ad-hoc signed); when set,
    /// staged updates must be signed by the same team.
    public func selfUpdateInstaller(
        bundleIdentifier: String, runner: any CommandRunner = ProcessCommandRunner(timeout: 180),
        runningTeamIdentifier: String? = PublisherCheck.runningTeamIdentifier()
    ) -> SelfUpdateInstaller {
        SelfUpdateInstaller(
            coordinator: self, bundleIdentifier: bundleIdentifier, runner: runner,
            runningTeamIdentifier: runningTeamIdentifier)
    }
}

/// Real `UpdateInstalling`: stage with `UpdateInstaller`, swap with `SelfUpdateReplacer` (old version to
/// quarantine), then clear `<support>/Updates/`.
public struct SelfUpdateInstaller: UpdateInstalling {
    let coordinator: OpenCleanCoordinator
    let bundleIdentifier: String
    let runner: any CommandRunner
    let runningTeamIdentifier: String?

    var replacer: SelfUpdateReplacer {
        SelfUpdateReplacer(
            store: coordinator.store, updatesDirectory: coordinator.updatesDirectory,
            bundleIdentifier: bundleIdentifier)
    }

    public func stage(_ download: VerifiedDownload) throws -> StagedUpdate {
        try UpdateInstaller(
            runner: runner, bundleIdentifier: bundleIdentifier, runningTeamIdentifier: runningTeamIdentifier
        ).stage(download)
    }

    public func installBlocker(currentApp: String) -> String? {
        do {
            try replacer.preflight(currentApp: currentApp)
            return nil
        } catch let error as SelfUpdateError {
            return Self.explain(error)
        } catch {
            return "OpenClean can't replace itself here: \(error.localizedDescription)."
        }
    }

    public func install(_ staged: StagedUpdate, currentApp: String) throws {
        try replacer.replace(currentApp: currentApp, with: staged.appPath)
        // Only after success: a failed install leaves the staged copy in place for Retry.
        coordinator.cleanUpUpdates()
    }

    static func explain(_ error: SelfUpdateError) -> String {
        switch error {
        case .translocated:
            "macOS is running OpenClean from a temporary, read-only copy. Drag OpenClean to your Applications folder, open it from there, and update again — or open the installer and copy it yourself."
        case .developmentBuild:
            "This is a development build, so OpenClean won't replace it. Open the installer to copy the new version yourself."
        case .readOnlyVolume:
            "OpenClean is running from a read-only disk. Open the installer and copy the new version to your Applications folder."
        case .notWritable:
            "You don't have permission to replace OpenClean where it's installed. Open the installer and copy the new version yourself."
        case .symlinkedPath:
            "OpenClean is opened through a symbolic link, so it won't replace itself. Open the installer and copy the new version yourself."
        case .differentVolume:
            "OpenClean is on a different disk from your home folder, so the current version can't be kept in History. Open the installer and copy the new version yourself."
        default:
            "OpenClean can't replace itself here (\(error.description)). Open the installer and copy the new version yourself."
        }
    }
}
