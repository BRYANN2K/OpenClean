import Foundation
import Quarantine

/// User preferences shared by the app and the CLI (`settings.json` in Application Support).
public struct Settings: Codable, Sendable, Equatable {
    public var retentionDays: Int
    public var advancedEnabled: Bool
    public var excludedPaths: [String]
    /// Extra folders the project probes search (Settings → Project folders), e.g. `~/Documents/Code`.
    /// Opt-in; empty by default. See `ProjectFolderExemption` for what this lets through.
    public var projectFolders: [String]

    public init(
        retentionDays: Int = 7, advancedEnabled: Bool = false, excludedPaths: [String] = [],
        projectFolders: [String] = []
    ) {
        self.retentionDays = retentionDays
        self.advancedEnabled = advancedEnabled
        self.excludedPaths = excludedPaths
        self.projectFolders = projectFolders
    }

    enum CodingKeys: String, CodingKey { case retentionDays, advancedEnabled, excludedPaths, projectFolders }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 7
        advancedEnabled = try c.decodeIfPresent(Bool.self, forKey: .advancedEnabled) ?? false
        excludedPaths = try c.decodeIfPresent([String].self, forKey: .excludedPaths) ?? []
        projectFolders = try c.decodeIfPresent([String].self, forKey: .projectFolders) ?? []
    }

    public var clampedRetentionDays: Int {
        min(max(retentionDays, Purger.retentionRange.lowerBound), Purger.retentionRange.upperBound)
    }
}

public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> Settings {
        guard let data = try? Data(contentsOf: url),
            var settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        settings.retentionDays = settings.clampedRetentionDays
        return settings
    }

    public func save(_ settings: Settings) throws {
        var clamped = settings
        clamped.retentionDays = settings.clampedRetentionDays
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(clamped).write(to: url, options: .atomic)
    }
}
