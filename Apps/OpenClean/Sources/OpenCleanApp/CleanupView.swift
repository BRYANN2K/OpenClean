import AppKit
import OpenCleanAppModel
import QuickLook
import RuleKit
import ScanEngine
import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var category: RuleCategory?
    @State private var ruleID: String?
    @State private var previewURL: URL?

    var body: some View {
        if let result = model.result {
            HSplitView {
                List(result.categories, id: \.category, selection: $category) { entry in
                    HStack {
                        CheckboxButton(state: model.state(of: entry.category), label: entry.category.displayName) {
                            model.setSelected(model.state(of: entry.category) != .on, category: entry.category)
                        }
                        Text(entry.category.displayName)
                        Spacer()
                        Text(formatBytes(entry.rules.reduce(Int64(0)) { $0 + $1.totalSize }))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 220)

                List(rules(in: result), selection: $ruleID) { rule in
                    HStack {
                        CheckboxButton(state: model.state(of: rule), label: rule.rule.name) {
                            model.setSelected(model.state(of: rule) != .on, rule: rule)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.rule.name)
                            SafetyBadge(safety: rule.rule.safety)
                        }
                        Spacer()
                        Text(detail(for: rule)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 280)

                RuleDetailView(rule: selectedRule(in: result), previewURL: $previewURL)
                    .frame(minWidth: 380)
            }
            .quickLookPreview($previewURL)
        } else {
            ContentUnavailableView(
                "No scan yet", systemImage: "magnifyingglass",
                description: Text("Run Smart Scan to see what can be cleaned."))
        }
    }

    private func rules(in result: ScanResult) -> [RuleResult] {
        let shown = category ?? result.categories.first?.category
        return result.rules.filter { $0.rule.category == shown }
    }

    private func selectedRule(in result: ScanResult) -> RuleResult? {
        if let ruleID, let match = result.rule(ruleID), rules(in: result).contains(where: { $0.id == match.id }) {
            return match
        }
        return rules(in: result).first
    }

    private func detail(for rule: RuleResult) -> String {
        switch rule.status {
        case .scanned: formatBytes(rule.totalSize)
        case .needsFullDiskAccess: "Needs access"
        case .skippedAppRunning: "App running"
        case .cancelled: "Cancelled"
        }
    }
}

struct RuleDetailView: View {
    @Environment(AppModel.self) private var model
    let rule: RuleResult?
    @Binding var previewURL: URL?

    var body: some View {
        if let rule {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(rule.rule.name).font(.title2.bold())
                    SafetyBadge(safety: rule.rule.safety)
                }
                Text(rule.rule.explain)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .skippedAppRunning(let app) = rule.status {
                    Label("Skipped while \(app) is running. Quit it and scan again.", systemImage: "app.badge")
                }
                if rule.status == .needsFullDiskAccess {
                    Label("Grant Full Disk Access to scan this.", systemImage: "lock")
                }
                Table(rule.items) {
                    TableColumn("") { item in
                        CheckboxButton(
                            state: model.selectedPaths.contains(item.path) ? .on : .off,
                            label: (item.path as NSString).lastPathComponent
                        ) { model.toggle(item) }
                        .disabled(item.reportOnly)
                    }
                    .width(28)
                    TableColumn("Item") { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text((item.path as NSString).lastPathComponent)
                            Text(item.hint ?? item.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                            }
                            Button("Quick Look") { previewURL = URL(fileURLWithPath: item.path) }
                        }
                    }
                    TableColumn("Size") { item in
                        Text(formatBytes(item.size)).monospacedDigit()
                    }
                    .width(90)
                }
                if !rule.errors.isEmpty {
                    DisclosureGroup("\(rule.errors.count) note(s)") {
                        ForEach(rule.errors, id: \.self) { note in
                            Text(note).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(16)
        } else {
            ContentUnavailableView("Select a rule", systemImage: "list.bullet")
        }
    }
}
