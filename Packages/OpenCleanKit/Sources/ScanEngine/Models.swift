import Foundation
import RuleKit

/// One removable entry found by a rule: a file or a directory (removed as a whole).
public struct ScanItem: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let ruleID: String
    public let size: Int64
    public let device: Int32
    public let inode: UInt64
    public let modificationDate: Date
    public let ownerUID: UInt32
    /// Shown with size and hint, but never selectable or removable.
    public let reportOnly: Bool
    public let hint: String?

    public init(
        path: String, ruleID: String, size: Int64, device: Int32, inode: UInt64,
        modificationDate: Date, ownerUID: UInt32, reportOnly: Bool = false, hint: String? = nil
    ) {
        self.path = path
        self.ruleID = ruleID
        self.size = size
        self.device = device
        self.inode = inode
        self.modificationDate = modificationDate
        self.ownerUID = ownerUID
        self.reportOnly = reportOnly
        self.hint = hint
    }

    /// A report-only entry that is not a filesystem path (e.g. a Time Machine snapshot).
    public static func virtual(path: String, ruleID: String, hint: String?) -> ScanItem {
        ScanItem(
            path: path, ruleID: ruleID, size: 0, device: 0, inode: 0,
            modificationDate: .distantPast, ownerUID: 0, reportOnly: true, hint: hint)
    }

    /// A fresh snapshot of an existing path, recorded the same way the scanner does.
    public static func snapshot(of path: String, ruleID: String) -> ScanItem? {
        guard let stat = FileStat.of(path) else { return nil }
        return ScanItem(
            path: path, ruleID: ruleID, size: FileSizer.allocatedSize(of: path, ledger: HardLinkLedger()),
            device: stat.device, inode: stat.inode, modificationDate: stat.modificationDate,
            ownerUID: stat.ownerUID)
    }
}

public enum RuleScanStatus: Sendable, Equatable {
    case scanned
    case needsFullDiskAccess
    case skippedAppRunning(String)
    case cancelled
}

public struct RuleResult: Sendable, Identifiable {
    public var id: String { rule.id }
    public let rule: Rule
    public var items: [ScanItem]
    public var status: RuleScanStatus
    public var errors: [String]

    public init(rule: Rule, items: [ScanItem] = [], status: RuleScanStatus = .scanned, errors: [String] = []) {
        self.rule = rule
        self.items = items
        self.status = status
        self.errors = errors
    }

    /// Bytes that can actually be removed (report-only items excluded).
    public var totalSize: Int64 { items.filter { !$0.reportOnly }.reduce(0) { $0 + $1.size } }
}

public struct ScanResult: Sendable {
    public var rules: [RuleResult]
    public var isComplete: Bool
    public var startedAt: Date
    public var finishedAt: Date

    public init(rules: [RuleResult], isComplete: Bool, startedAt: Date, finishedAt: Date) {
        self.rules = rules
        self.isComplete = isComplete
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var totalSize: Int64 { rules.reduce(0) { $0 + $1.totalSize } }
    public var allItems: [ScanItem] { rules.flatMap(\.items) }
    public func rule(_ id: String) -> RuleResult? { rules.first { $0.rule.id == id } }

    /// Rule results grouped by category in `RuleCategory.allCases` order; empty categories omitted.
    public var categories: [(category: RuleCategory, rules: [RuleResult])] {
        RuleCategory.allCases.compactMap { category in
            let matching = rules.filter { $0.rule.category == category }
            return matching.isEmpty ? nil : (category, matching)
        }
    }
}

public struct ScanProgress: Sendable, Equatable {
    public let ruleID: String
    public let finished: Int
    public let total: Int

    public init(ruleID: String, finished: Int, total: Int) {
        self.ruleID = ruleID
        self.finished = finished
        self.total = total
    }

    public var fraction: Double { total == 0 ? 1 : Double(finished) / Double(total) }
}

/// Everything a scan needs from the outside world. `home` is injected so tests never touch the real one.
public struct ScanContext: Sendable {
    public var home: String
    public var hasFullDiskAccess: Bool
    public var processChecker: any ProcessChecker
    /// Absolute paths the user excluded in Settings; items equal to or inside them are skipped.
    public var userExcludes: [String]
    /// Extra folders the user asked the project probes to search (Settings → Project folders), resolved;
    /// folders `ProjectFolderExemption.problem(with:home:)` rejects are dropped.
    public var projectFolders: [String]
    public var now: Date

    public init(
        home: String, hasFullDiskAccess: Bool, processChecker: any ProcessChecker,
        userExcludes: [String] = [], projectFolders: [String] = [], now: Date = .now
    ) {
        self.home = realPath(home) ?? home
        self.hasFullDiskAccess = hasFullDiskAccess
        self.processChecker = processChecker
        self.userExcludes = userExcludes.map { exclude in
            realPath(exclude) ?? (exclude.count > 1 && exclude.hasSuffix("/") ? String(exclude.dropLast()) : exclude)
        }
        let resolvedHome = self.home
        self.projectFolders = projectFolders.compactMap { realPath($0) }.filter {
            ProjectFolderExemption.problem(with: $0, home: resolvedHome) == nil
        }
        self.now = now
    }

    public var expander: PathExpander { PathExpander(home: home) }
    public var denyList: DenyList { DenyList(home: home) }
    public var projectFolderExemption: ProjectFolderExemption {
        ProjectFolderExemption(home: home, folders: projectFolders)
    }
}
