import Foundation

/// Staging and in-place installation, as seen by the app model. The real implementation
/// (`SelfUpdateInstaller` in OpenCleanKit) combines `UpdateInstaller`, Quarantine's
/// `SelfUpdateReplacer` and `UpdateStagingCleaner`; tests substitute a fake that never touches an app.
public protocol UpdateInstalling: Sendable {
    /// Mounts the verified image, copies and validates the app. Slow (hdiutil, ditto, codesign).
    func stage(_ download: VerifiedDownload) throws -> StagedUpdate
    /// Nil when the running app at `currentApp` can be replaced in place; otherwise a sentence saying why not.
    func installBlocker(currentApp: String) -> String?
    /// Moves the current app to quarantine and the staged app into its place.
    func install(_ staged: StagedUpdate, currentApp: String) throws
}
