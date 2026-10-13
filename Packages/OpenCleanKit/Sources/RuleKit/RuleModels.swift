import Foundation

public enum SafetyLevel: String, Codable, Sendable, CaseIterable {
    case regenerable, review, caution

    public var defaultDeleteMode: DeleteMode { self == .regenerable ? .immediate : .quarantine }
    public var isSelectedByDefault: Bool { self == .regenerable }
}

public enum DeleteMode: String, Codable, Sendable {
    case immediate, quarantine
}

public enum RuleCategory: String, Codable, Sendable, CaseIterable {
    case system, user, browsers, developer, ai, mail, trash, ios

    public var displayName: String {
        switch self {
        case .system: "System Junk"
        case .user: "User Caches & Logs"
        case .browsers: "Browser Caches"
        case .developer: "Developer Tools"
        case .ai: "AI Models & Caches"
        case .mail: "Mail Attachments"
        case .trash: "Trash"
        case .ios: "iOS Backups"
        }
    }
}

public enum Requirement: String, Codable, Sendable {
    case fullDiskAccess = "full_disk_access"
    case admin
}

public struct RuleConditions: Decodable, Sendable, Equatable {
    public var appNotRunning: [String]
    public var minAgeDays: Int?
    public var minSize: ByteSize?

    public init(appNotRunning: [String] = [], minAgeDays: Int? = nil, minSize: ByteSize? = nil) {
        self.appNotRunning = appNotRunning
        self.minAgeDays = minAgeDays
        self.minSize = minSize
    }

    enum CodingKeys: String, CodingKey {
        case appNotRunning = "app_not_running"
        case minAgeDays = "min_age_days"
        case minSize = "min_size"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try? container.decode([String].self, forKey: .appNotRunning) {
            appNotRunning = list
        } else if let single = try container.decodeIfPresent(String.self, forKey: .appNotRunning) {
            appNotRunning = [single]
        } else {
            appNotRunning = []
        }
        minAgeDays = try container.decodeIfPresent(Int.self, forKey: .minAgeDays)
        minSize = try container.decodeIfPresent(ByteSize.self, forKey: .minSize)
    }
}

public struct Rule: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var category: RuleCategory
    public var explain: String
    public var paths: [String]
    public var probe: String?
    public var safety: SafetyLevel
    public var deleteMode: DeleteMode?
    public var conditions: RuleConditions
    public var exclude: [String]
    public var requires: [Requirement]
    /// `make_writable: true`: before deleting an item, give the user write permission on the folders they
    /// own inside it (tools such as Go make their module cache read-only, so a plain delete fails partway).
    /// Only for rules that delete immediately and don't need admin (the linter enforces this).
    public var makeWritable: Bool

    public init(
        id: String, name: String, category: RuleCategory, explain: String,
        paths: [String] = [], probe: String? = nil, safety: SafetyLevel,
        deleteMode: DeleteMode? = nil, conditions: RuleConditions = RuleConditions(),
        exclude: [String] = [], requires: [Requirement] = [], makeWritable: Bool = false
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.explain = explain
        self.paths = paths
        self.probe = probe
        self.safety = safety
        self.deleteMode = deleteMode
        self.conditions = conditions
        self.exclude = exclude
        self.requires = requires
        self.makeWritable = makeWritable
    }

    enum CodingKeys: String, CodingKey {
        case id, name, category, explain, paths, probe, safety, conditions, exclude, requires
        case deleteMode = "delete_mode"
        case makeWritable = "make_writable"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decode(RuleCategory.self, forKey: .category)
        explain = try c.decode(String.self, forKey: .explain)
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        probe = try c.decodeIfPresent(String.self, forKey: .probe)
        safety = try c.decode(SafetyLevel.self, forKey: .safety)
        deleteMode = try c.decodeIfPresent(DeleteMode.self, forKey: .deleteMode)
        conditions = try c.decodeIfPresent(RuleConditions.self, forKey: .conditions) ?? RuleConditions()
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        requires = try c.decodeIfPresent([Requirement].self, forKey: .requires) ?? []
        makeWritable = try c.decodeIfPresent(Bool.self, forKey: .makeWritable) ?? false
    }

    public var effectiveDeleteMode: DeleteMode { deleteMode ?? safety.defaultDeleteMode }

    public func needs(_ requirement: Requirement) -> Bool { requires.contains(requirement) }
}

public struct RulePack: Decodable, Sendable, Equatable {
    public var pack: String
    public var version: Int
    public var rules: [Rule]
    /// File the pack was loaded from; not part of the YAML.
    public var sourcePath: String? = nil

    enum CodingKeys: String, CodingKey { case pack, version, rules }

    public init(pack: String, version: Int = 1, rules: [Rule], sourcePath: String? = nil) {
        self.pack = pack
        self.version = version
        self.rules = rules
        self.sourcePath = sourcePath
    }
}
