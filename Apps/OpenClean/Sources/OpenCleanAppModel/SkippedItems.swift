import Foundation
import Quarantine

/// Items a clean left in place, grouped by why, for the cleanup summary's details.
public struct SkippedItems: Equatable, Sendable {
    public struct Group: Equatable, Sendable, Identifiable {
        /// Why, in plain words ("Changed since the scan; an app may be using it.").
        public let explanation: String
        /// The items' original paths, in manifest order.
        public let paths: [String]
        public var id: String { explanation }
    }

    public let groups: [Group]
    /// True when scanning again could let at least one item be cleaned (it changed, was in use, ...).
    public let suggestsRescan: Bool

    public init(report: RemovalReport) {
        self.init(entries: report.skipped)
    }

    public init(entries: [ManifestEntry]) {
        var order: [String] = []
        var paths: [String: [String]] = [:]
        for entry in entries {
            guard let explanation = Self.explanation(for: entry) else { continue }
            if paths[explanation] == nil { order.append(explanation) }
            paths[explanation, default: []].append(entry.originalPath)
        }
        groups = order.map { Group(explanation: $0, paths: paths[$0] ?? []) }
        suggestsRescan = entries.contains(where: \.isWorthRescanning)
    }

    public var count: Int { groups.reduce(0) { $0 + $1.paths.count } }
    public var isEmpty: Bool { groups.isEmpty }

    /// "2 items were left in place", or "1 item was left in place".
    public var headline: String {
        String(localized: "\(count) items were left in place", bundle: .appModel)
    }

    /// One line under the headline: the reason when there is only one, otherwise a pointer to the details.
    public var summary: String {
        if groups.count == 1, let only = groups.first { return only.explanation }
        return String(localized: "For different reasons; see the details.", bundle: .appModel)
    }

    /// `ManifestEntry.plainSkipExplanation`, translated: why the entry was left in place; nil unless it was
    /// skipped or failed. A failed removal's own message comes from macOS and is shown as recorded.
    public static func explanation(for entry: ManifestEntry) -> String? {
        let parsed = entry.reason.flatMap(SkipReason.init(recorded:))
        switch entry.outcome {
        case .skipped:
            if let parsed { return explanation(for: parsed) }
            if let reason = entry.reason { return String(localized: "Skipped: \(reason).", bundle: .appModel) }
            return String(localized: "Skipped.", bundle: .appModel)
        case .failed:
            if let parsed { return explanation(for: parsed) }
            return entry.reason ?? String(localized: "Couldn't be removed.", bundle: .appModel)
        default:
            return nil
        }
    }

    /// `SkipReason.plainExplanation`, translated.
    public static func explanation(for reason: SkipReason) -> String {
        switch reason {
        case .reportOnly:
            String(localized: "Shown for information only. OpenClean never removes it.", bundle: .appModel)
        case .missing:
            String(localized: "Already gone. Something else removed it after the scan.", bundle: .appModel)
        case .changedSinceScan:
            String(localized: "Changed since the scan; an app may be using it.", bundle: .appModel)
        case .inUse:
            String(localized: "Open in another app. Quit the app, then scan again.", bundle: .appModel)
        case .openFilesUnknown:
            String(
                localized: "OpenClean couldn't check whether another app had it open, so it left it alone.",
                bundle: .appModel)
        case .appRunning(let app):
            String(localized: "\(app) was running. Quit it, then scan again.", bundle: .appModel)
        case .protected:
            String(localized: "In a protected location. OpenClean never removes it.", bundle: .appModel)
        case .adminCancelled:
            String(localized: "The administrator password prompt was cancelled.", bundle: .appModel)
        case .adminUnsupportedPath:
            String(localized: "Its path can't be passed safely to the administrator prompt.", bundle: .appModel)
        case .adminBatchFull:
            String(
                localized: "Too many system items for one password prompt. Clean again to remove the rest.",
                bundle: .appModel)
        case .adminUnsafeParent:
            String(
                localized: "A folder above it isn't protected by macOS, so it wasn't removed as administrator.",
                bundle: .appModel)
        case .adminRequiresImmediate:
            String(localized: "System items can only be deleted, not moved to quarantine.", bundle: .appModel)
        case .appNotMoved:
            String(localized: "The app wasn't moved, so this was left in place.", bundle: .appModel)
        }
    }
}
