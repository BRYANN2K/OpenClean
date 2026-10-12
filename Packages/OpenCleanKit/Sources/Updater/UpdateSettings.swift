import Foundation

/// Update preferences, kept in `UserDefaults` (the app's own domain) rather than `settings.json`:
/// they belong to the app only (the CLI never checks for updates), like the menu bar and onboarding
/// flags that already live there.
///
/// - `updates.autoCheck`: check once a day. **On by default** (an unset key reads as true).
/// - `updates.lastCheck`: when the last check finished successfully.
/// - `updates.skippedVersion`: "Skip This Version"; that release is no longer announced.
/// - `updates.relaunchedFrom`: set just before relaunching into a new version, so the next launch
///   can explain that Full Disk Access needs to be allowed again.
public final class UpdateSettingsStore: @unchecked Sendable {
    public static let autoCheckKey = "updates.autoCheck"
    public static let lastCheckKey = "updates.lastCheck"
    public static let skippedVersionKey = "updates.skippedVersion"
    public static let relaunchedFromKey = "updates.relaunchedFrom"
    public static let relaunchedToKey = "updates.relaunchedTo"

    let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var autoCheck: Bool {
        get { defaults.object(forKey: Self.autoCheckKey) == nil ? true : defaults.bool(forKey: Self.autoCheckKey) }
        set { defaults.set(newValue, forKey: Self.autoCheckKey) }
    }

    public var lastCheck: Date? {
        get { defaults.object(forKey: Self.lastCheckKey) as? Date }
        set { defaults.set(newValue, forKey: Self.lastCheckKey) }
    }

    public var skippedVersion: SemanticVersion? {
        get { defaults.string(forKey: Self.skippedVersionKey).flatMap(SemanticVersion.init) }
        set { defaults.set(newValue?.description, forKey: Self.skippedVersionKey) }
    }

    /// Records the hand-over before the relaunch helper starts.
    public func recordRelaunch(from old: SemanticVersion?, to new: SemanticVersion) {
        defaults.set(old?.description, forKey: Self.relaunchedFromKey)
        defaults.set(new.description, forKey: Self.relaunchedToKey)
    }

    /// If this launch is the first one after an in-app update to `current`, returns the version it
    /// came from (or `current` when unknown) and forgets the record.
    public func consumeRelaunch(current: SemanticVersion?) -> SemanticVersion? {
        guard let target = defaults.string(forKey: Self.relaunchedToKey).flatMap(SemanticVersion.init) else {
            return nil
        }
        let from = defaults.string(forKey: Self.relaunchedFromKey).flatMap(SemanticVersion.init)
        defaults.removeObject(forKey: Self.relaunchedToKey)
        defaults.removeObject(forKey: Self.relaunchedFromKey)
        guard let current, current == target else { return nil }
        return from ?? current
    }
}
