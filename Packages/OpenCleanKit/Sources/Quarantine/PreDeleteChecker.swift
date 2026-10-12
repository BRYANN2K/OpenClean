import Foundation
import RuleKit
import ScanEngine

public enum SkipReason: Sendable, Equatable, CustomStringConvertible {
    case reportOnly
    case missing
    case changedSinceScan
    case inUse
    case openFilesUnknown
    case appRunning(String)
    case protected(String)
    case adminCancelled
    case adminUnsupportedPath
    case adminBatchFull

    public var description: String {
        switch self {
        case .reportOnly: "report-only item; never removed"
        case .missing: "no longer exists"
        case .changedSinceScan: "changed since the scan"
        case .inUse: "open in another app"
        case .openFilesUnknown: "could not check for open files"
        case .appRunning(let id): "\(id) is running"
        case .protected(let reason): "protected (\(reason))"
        case .adminCancelled: "administrator prompt was cancelled"
        case .adminUnsupportedPath: "path cannot be passed safely to the administrator prompt"
        case .adminBatchFull: "too many system items for one prompt; run cleanup again"
        }
    }
}

/// Last checks right before an item is removed. Any failure means "skip and record why".
public struct PreDeleteChecker: Sendable {
    let denyList: DenyList
    let processChecker: any ProcessChecker
    /// Open paths plus all their ancestors; nil when open files could not be determined.
    let busy: Set<String>?

    public init(denyList: DenyList, processChecker: any ProcessChecker, openPaths: Set<String>?) {
        self.denyList = denyList
        self.processChecker = processChecker
        guard let openPaths else {
            busy = nil
            return
        }
        var expanded = Set<String>()
        for path in openPaths {
            expanded.insert(path)
            var parent = (path as NSString).deletingLastPathComponent
            while parent.count > 1 {
                expanded.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        busy = expanded
    }

    public func check(_ item: ScanItem, rule: Rule) -> SkipReason? {
        if item.reportOnly { return .reportOnly }
        guard let stat = FileStat.of(item.path) else { return .missing }
        if stat.inode != item.inode || stat.device != item.device || stat.modificationDate != item.modificationDate {
            return .changedSinceScan
        }
        if let reason = denyList.denialReason(for: item.path) { return .protected(reason) }
        if let app = rule.conditions.appNotRunning.first(where: { processChecker.isRunning(bundleID: $0) }) {
            return .appRunning(app)
        }
        guard let busy else { return .openFilesUnknown }
        if busy.contains(item.path) { return .inUse }
        return nil
    }
}
