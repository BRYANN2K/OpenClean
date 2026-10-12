import Foundation
import RuleKit

/// Checks that apply before a rule is scanned at all.
enum Gate {
    static func check(_ rule: Rule, _ context: ScanContext) -> RuleScanStatus? {
        if rule.needs(.fullDiskAccess) && !context.hasFullDiskAccess {
            return .needsFullDiskAccess
        }
        if let running = rule.conditions.appNotRunning.first(where: { context.processChecker.isRunning(bundleID: $0) }) {
            return .skippedAppRunning(running)
        }
        return nil
    }
}

enum BuildOutcome {
    case item(ScanItem)
    case dropped(String)
    case filtered
}

/// Turns a candidate path into a `ScanItem`, applying resolution, deny-list and conditions.
enum ItemBuilder {
    static func build(
        path: String, within prefixReal: String?, rule: Rule, context: ScanContext,
        ledger: HardLinkLedger, reportOnly: Bool = false, hint: String? = nil
    ) -> BuildOutcome {
        guard let stat = FileStat.of(path) else { return .dropped("disappeared during scan") }
        if stat.isSymlink { return .dropped("symbolic link skipped") }
        guard let real = realPath(path) else { return .dropped("cannot resolve path") }
        if let prefixReal, real != prefixReal, !real.hasPrefix(prefixReal == "/" ? "/" : prefixReal + "/") {
            return .dropped("resolves outside \(prefixReal)")
        }
        if let reason = context.denyList.denialReason(for: real) {
            return .dropped("protected: \(reason)")
        }
        // Items are removed whole, so an exclude equal to, inside, or above the item protects it.
        let lowerReal = real.lowercased()
        let isExcluded = context.userExcludes.contains { exclude in
            let lowerExclude = exclude.lowercased()
            return lowerReal == lowerExclude
                || lowerReal.hasPrefix(lowerExclude == "/" ? "/" : lowerExclude + "/")
                || lowerExclude.hasPrefix(lowerReal + "/")
        }
        if isExcluded { return .filtered }
        if let days = rule.conditions.minAgeDays,
            stat.modificationDate > context.now.addingTimeInterval(-Double(days) * 86_400)
        {
            return .filtered
        }
        let size = FileSizer.allocatedSize(of: real, ledger: ledger)
        if let minimum = rule.conditions.minSize, size < minimum.bytes {
            return .filtered
        }
        return .item(
            ScanItem(
                path: real, ruleID: rule.id, size: size, device: stat.device, inode: stat.inode,
                modificationDate: stat.modificationDate, ownerUID: stat.ownerUID,
                reportOnly: reportOnly, hint: hint))
    }
}
