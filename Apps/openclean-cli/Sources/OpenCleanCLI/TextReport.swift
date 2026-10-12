import Foundation
import OpenCleanKit
import Quarantine
import RuleKit
import ScanEngine

/// Human-readable output. Not a stable interface; scripts should use --json.
public enum TextReport {
    static func size(_ bytes: Int64) -> String { ByteSize.format(bytes) }

    public static func scan(_ result: ScanResult) -> String {
        var lines: [String] = []
        for (category, rules) in result.categories {
            lines.append(category.displayName)
            for ruleResult in rules {
                let removable = ruleResult.items.filter { !$0.reportOnly }.count
                let detail =
                    ruleResult.status == .scanned
                    ? "\(size(ruleResult.totalSize)) in \(removable) item(s)"
                    : statusText(ruleResult.status)
                lines.append("  \(ruleResult.rule.name) [\(ruleResult.rule.id)]  \(detail)")
                for item in ruleResult.items where item.reportOnly {
                    lines.append("    info: \(item.path)  \(size(item.size))  \(item.hint ?? "")")
                }
            }
        }
        lines.append("")
        lines.append("Total removable: \(size(result.totalSize))")
        if !result.isComplete { lines.append("Scan was cancelled; results are partial.") }
        let needsAccess = result.rules.filter { $0.status == .needsFullDiskAccess }.map(\.rule.id)
        if !needsAccess.isEmpty {
            lines.append("Needs Full Disk Access: \(needsAccess.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    static func statusText(_ status: RuleScanStatus) -> String {
        switch status {
        case .scanned: "scanned"
        case .needsFullDiskAccess: "needs Full Disk Access"
        case .skippedAppRunning(let id): "skipped while \(id) is running"
        case .cancelled: "cancelled"
        }
    }

    public static func rules(_ rules: [Rule]) -> String {
        rules.map { "\($0.id)  [\($0.category.rawValue), \($0.safety.rawValue)]  \($0.name)" }
            .joined(separator: "\n")
    }

    public static func explain(_ rule: Rule) -> String {
        var lines = [
            "\(rule.name) [\(rule.id)]",
            rule.explain,
            "",
            "Category:    \(rule.category.displayName)",
            "Safety:      \(rule.safety.rawValue)",
            "Delete mode: \(rule.effectiveDeleteMode.rawValue)",
        ]
        if let probe = rule.probe { lines.append("Probe:       \(probe)") }
        if !rule.paths.isEmpty { lines.append("Paths:       " + rule.paths.joined(separator: "\n             ")) }
        if !rule.exclude.isEmpty { lines.append("Excludes:    " + rule.exclude.joined(separator: "\n             ")) }
        if !rule.conditions.appNotRunning.isEmpty {
            lines.append("Skipped while running: " + rule.conditions.appNotRunning.joined(separator: ", "))
        }
        if let days = rule.conditions.minAgeDays { lines.append("Only items older than \(days) days") }
        if let minimum = rule.conditions.minSize { lines.append("Only items larger than \(minimum)") }
        if !rule.requires.isEmpty {
            lines.append("Requires:    " + rule.requires.map(\.rawValue).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    public static func plan(_ plan: CleanupPlan, retentionDays: Int) -> String {
        var lines = ["Ready to remove \(plan.itemCount) item(s):"]
        lines.append("  Delete now:          \(size(plan.immediateBytes)) (\(plan.immediateRequests.count) items)")
        lines.append(
            "  Move to quarantine:  \(size(plan.quarantineBytes)) (\(plan.quarantineRequests.count) items, restorable for \(retentionDays) days)"
        )
        if !plan.adminRequests.isEmpty {
            lines.append("  \(plan.adminRequests.count) system item(s) need your administrator password.")
        }
        lines.append("Files that changed since the scan or are open in another app are skipped automatically.")
        return lines.joined(separator: "\n")
    }

    public static func cleanup(_ report: RemovalReport) -> String {
        var lines = [
            "Session \(report.manifest.id)",
            "  Freed now:    \(size(report.deletedBytes))",
            "  Quarantined:  \(size(report.quarantinedBytes))  (restore with `openclean restore \(report.manifest.id)`)",
        ]
        if report.hadSkips {
            lines.append("  Skipped \(report.skipped.count) item(s):")
            for entry in report.skipped {
                lines.append("    \(entry.originalPath): \(entry.reason ?? "unknown reason")")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func history(_ listings: [SessionListing]) -> String {
        guard !listings.isEmpty else { return "No cleanup sessions yet." }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return listings.map { listing in
            switch listing {
            case .ok(let manifest):
                let state = manifest.purgedAt == nil ? "" : "  (purged)"
                return
                    "\(manifest.id)  \(formatter.string(from: manifest.createdAt))  freed \(size(manifest.deletedBytes))  quarantined \(size(manifest.quarantinedBytes))  skipped \(manifest.skippedEntries.count)\(state)"
            case .damaged(let id, _):
                return "\(id)  damaged manifest"
            }
        }.joined(separator: "\n")
    }

    public static func restore(_ report: RestoreReport) -> String {
        var lines = ["Restored \(report.restored.count) item(s)."]
        for skip in report.skipped { lines.append("  Skipped \(skip.path): \(skip.reason)") }
        return lines.joined(separator: "\n")
    }
}
