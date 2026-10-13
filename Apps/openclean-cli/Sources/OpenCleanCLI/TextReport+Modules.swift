import AppInventory
import Foundation
import SpaceKit
import SystemMonitor

/// Human-readable output for `apps`, `space` and `performance`. Not a stable interface; use --json.
extension TextReport {
    // MARK: Apps

    static func apps(_ listings: [AppListing]) -> String {
        guard !listings.isEmpty else { return "No apps found." }
        var lines: [String] = []
        for listing in listings {
            let app = listing.app
            let removable = listing.leftovers.filter { !$0.isReportOnly }
            let leftoverBytes = removable.reduce(0) { $0 + $1.size }
            var detail = "\(size(app.size))"
            if !removable.isEmpty { detail += " + \(size(leftoverBytes)) in \(removable.count) leftover(s)" }
            let version = app.version.map { " \($0)" } ?? ""
            lines.append("\(app.name)\(version)  [\(app.bundleID ?? "no bundle id")]  \(detail)")
            var notes: [String] = []
            if !app.status.isRemovable || app.status.requiresAdministrator { notes.append(app.status.explanation) }
            if app.isRunning { notes.append("running") }
            if !notes.isEmpty { lines.append("  " + notes.joined(separator: "; ")) }
        }
        let total = listings.reduce(Int64(0)) { $0 + $1.app.size }
        lines.append("")
        lines.append("\(listings.count) app(s), \(size(total)). Details: openclean apps list --json")
        return lines.joined(separator: "\n")
    }

    static func uninstallPlan(_ plan: UninstallPlan, retentionDays: Int) -> String {
        let app = plan.listing.app
        var lines = ["Uninstall \(app.name)\(app.version.map { " " + $0 } ?? "") [\(app.bundleID ?? "")]"]
        lines.append("  \(app.path)  \(size(app.size))")
        if !plan.chosen.isEmpty {
            lines.append("  Leftovers to move (\(plan.chosen.count)):")
            for leftover in plan.chosen {
                lines.append("    \(leftover.path)  \(size(leftover.size))  (\(leftover.kind.displayName))")
            }
        }
        let names = plan.staying.filter { !$0.isReportOnly }
        if !names.isEmpty {
            lines.append("  Matched by name only, left in place (add --include-name-matches to move them):")
            for leftover in names { lines.append("    \(leftover.path)  \(size(leftover.size))") }
        }
        let system = plan.staying.filter(\.isReportOnly)
        if !system.isEmpty {
            lines.append("  In /Library, left in place (needs administrator, not supported yet):")
            for leftover in system { lines.append("    \(leftover.path)") }
        }
        lines.append(
            "Moves \(size(plan.totalBytes)) to quarantine, restorable for \(retentionDays) days with `openclean restore`."
        )
        if app.status.requiresAdministrator {
            lines.append(
                "\(app.name) is owned by the system: macOS will ask for your administrator password to move it. A restored copy comes back owned by you."
            )
        }
        if app.isRunning { lines.append("\(app.name) is running; quit it first.") }
        return lines.joined(separator: "\n")
    }

    // MARK: Space

    static func largeFiles(_ result: LargeFileResult, files: [LargeFile], filter: LargeFileFilter) -> String {
        var criteria = "at least \(size(filter.minimumSize))"
        if let days = filter.notOpenedForDays { criteria += ", not opened for \(days) days" }
        guard !files.isEmpty else { return "No files \(criteria)." + footer(result.unreadableCount, result.isComplete) }
        var lines = ["\(files.count) file(s) \(criteria), \(size(files.reduce(0) { $0 + $1.size })):"]
        for file in files {
            let opened = file.lastOpened.map { "  last opened \(day($0))" } ?? ""
            lines.append("  \(size(file.size))  \(file.path)  [\(file.kind.displayName)]\(opened)")
        }
        return lines.joined(separator: "\n") + footer(result.unreadableCount, result.isComplete)
    }

    static func duplicates(_ result: DuplicateResult) -> String {
        guard !result.groups.isEmpty else {
            return "No duplicates found." + footer(result.unreadableCount, result.isComplete)
        }
        var lines = [
            "\(result.groups.count) group(s) of identical files; keeping one copy of each would free \(size(result.reclaimable)):"
        ]
        for group in result.groups {
            lines.append("  \(group.files.count) × \(size(group.logicalSize))  sha256 \(group.id.prefix(12))")
            for file in group.files {
                lines.append("    \(file.path)\(file.path == group.suggestedKeep ? "  (suggested keep)" : "")")
            }
        }
        if result.unhashable > 0 { lines.append("\(result.unhashable) file(s) could not be read to compare.") }
        return lines.joined(separator: "\n") + footer(result.unreadableCount, result.isComplete)
    }

    static func footer(_ unreadable: Int, _ complete: Bool) -> String {
        var lines: [String] = []
        if unreadable > 0 { lines.append("\(unreadable) folder(s) could not be read (Full Disk Access may help).") }
        if !complete { lines.append("The search was cancelled; results are partial.") }
        lines.append("Nothing was removed.")
        return "\n" + lines.joined(separator: "\n")
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    // MARK: Performance

    static func performance(_ snapshot: PerformanceSnapshot) -> String {
        let monitor = snapshot.monitor
        var lines: [String] = []
        if let cpu = monitor.cpu { lines.append("CPU:     \(percent(cpu * 100)) of all cores") }
        if let memory = monitor.memory {
            lines.append(
                "Memory:  \(ram(memory.used)) of \(ram(memory.total)) used (app \(ram(memory.appMemory)), wired \(ram(memory.wired)), compressed \(ram(memory.compressed))); pressure \(memory.pressure.rawValue)"
            )
        }
        if let disk = monitor.disk {
            lines.append("Disk:    \(size(disk.available)) free of \(size(disk.total))")
        }
        lines.append("")
        lines.append("Top CPU (over \(String(format: "%.1f", snapshot.interval)) s):")
        lines.append(
            contentsOf: snapshot.topCPU.map { "  \(percent($0.cpuPercent))  \(ram($0.residentBytes))  \(label($0))" })
        lines.append("")
        lines.append("Top memory:")
        lines.append(
            contentsOf: snapshot.topMemory.map { "  \(ram($0.residentBytes))  \(percent($0.cpuPercent))  \(label($0))" }
        )
        lines.append("")
        lines.append("Only your own processes can be measured without administrator rights. Nothing was quit.")
        return lines.joined(separator: "\n")
    }

    static func percent(_ value: Double) -> String { String(format: "%5.1f%%", value) }
    static func ram(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    static func label(_ group: ProcessGroup) -> String {
        let count = group.processes.count > 1 ? " (\(group.processes.count) processes)" : ""
        return group.name + count
    }
}
