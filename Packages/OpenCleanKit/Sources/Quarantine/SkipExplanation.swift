import Foundation

extension SkipReason {
    /// Why the item was left in place, in plain words for the cleanup summary.
    public var plainExplanation: String {
        switch self {
        case .reportOnly: "Shown for information only. OpenClean never removes it."
        case .missing: "Already gone. Something else removed it after the scan."
        case .changedSinceScan: "Changed since the scan; an app may be using it."
        case .inUse: "Open in another app. Quit the app, then scan again."
        case .openFilesUnknown: "OpenClean couldn't check whether another app had it open, so it left it alone."
        case .appRunning(let app): "\(app) was running. Quit it, then scan again."
        case .protected: "In a protected location. OpenClean never removes it."
        case .adminCancelled: "The administrator password prompt was cancelled."
        case .adminUnsupportedPath: "Its path can't be passed safely to the administrator prompt."
        case .adminBatchFull: "Too many system items for one password prompt. Clean again to remove the rest."
        case .adminUnsafeParent: "A folder above it isn't protected by macOS, so it wasn't removed as administrator."
        case .adminRequiresImmediate: "System items can only be deleted, not moved to quarantine."
        case .appNotMoved: "The app wasn't moved, so this was left in place."
        }
    }

    /// True when scanning again can find the item in a state that can be cleaned (it changed, was busy, or
    /// an app was running).
    public var isWorthRescanning: Bool {
        switch self {
        case .missing, .changedSinceScan, .inUse, .openFilesUnknown, .appRunning, .adminCancelled, .adminBatchFull:
            true
        default: false
        }
    }

    static let withoutValues: [SkipReason] = [
        .reportOnly, .missing, .changedSinceScan, .inUse, .openFilesUnknown, .adminCancelled,
        .adminUnsupportedPath, .adminBatchFull, .adminUnsafeParent, .adminRequiresImmediate, .appNotMoved,
    ]

    /// The reason a session manifest recorded (`description`), parsed back; nil if it isn't one (for example
    /// the error message of a failed removal).
    public init?(recorded: String) {
        if let match = Self.withoutValues.first(where: { $0.description == recorded }) {
            self = match
        } else if recorded.hasSuffix(" is running"), recorded.count > " is running".count {
            self = .appRunning(String(recorded.dropLast(" is running".count)))
        } else if recorded.hasPrefix("protected ("), recorded.hasSuffix(")") {
            self = .protected(String(recorded.dropFirst("protected (".count).dropLast()))
        } else {
            return nil
        }
    }
}

extension ManifestEntry {
    /// Why this entry was left in place, in plain words; nil unless it was skipped or failed.
    public var plainSkipExplanation: String? {
        switch outcome {
        case .skipped:
            if let reason, let parsed = SkipReason(recorded: reason) { return parsed.plainExplanation }
            return reason.map { "Skipped: \($0)." } ?? "Skipped."
        case .failed:
            if let reason, let parsed = SkipReason(recorded: reason) { return parsed.plainExplanation }
            // A failed removal records the system's own message, which is already a sentence.
            return reason ?? "Couldn't be removed."
        default:
            return nil
        }
    }

    /// True when scanning again might let this entry be cleaned.
    public var isWorthRescanning: Bool {
        guard outcome == .skipped || outcome == .failed else { return false }
        return reason.flatMap(SkipReason.init(recorded:))?.isWorthRescanning ?? false
    }
}
