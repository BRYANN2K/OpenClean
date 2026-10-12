import OpenCleanAppModel
import Quarantine
import RuleKit
import ScanEngine
import SwiftUI

struct SmartScanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .idle:
            VStack(spacing: 16) {
                Image(systemName: "sparkles").font(.system(size: 56)).foregroundStyle(.tint)
                Text("Smart Scan").font(.largeTitle.bold())
                Text("Finds caches, logs and leftovers you can safely remove. Nothing is removed until you review it.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                Button("Scan") { model.startScan() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(40)
        case .scanning:
            VStack(spacing: 16) {
                ProgressView(value: model.progress?.fraction ?? 0) {
                    Text("Scanning…")
                } currentValueLabel: {
                    Text(model.progress?.ruleID ?? "Starting")
                }
                .frame(maxWidth: 420)
                Button("Cancel") { model.cancelScan() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(40)
        case .results, .cleaning, .finished:
            ResultsSummaryView()
        }
    }
}

struct ResultsSummaryView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let result = model.result, !result.isComplete {
                        Label("The scan was cancelled. Results are partial.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if let report = model.lastReport {
                        CleanupSummary(report: report)
                    }
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.result?.categories ?? [], id: \.category) { entry in
                            CategoryCard(category: entry.category, rules: entry.rules)
                        }
                    }
                }
                .padding(24)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected: \(formatBytes(model.plan?.totalBytes ?? 0))").font(.headline)
                    Text(
                        "\(formatBytes(model.plan?.immediateBytes ?? 0)) freed now · \(formatBytes(model.plan?.quarantineBytes ?? 0)) to quarantine"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if model.phase == .cleaning { ProgressView().controlSize(.small) }
                Button("Scan Again") { model.startScan() }
                    .disabled(model.phase == .cleaning)
                Button("Review & Clean…") { model.isReviewPresented = true }
                    .buttonStyle(.borderedProminent)
                    .disabled((model.plan?.isEmpty ?? true) || model.phase != .results)
            }
            .padding(16)
        }
    }
}

struct CategoryCard: View {
    @Environment(AppModel.self) private var model
    let category: RuleCategory
    let rules: [RuleResult]

    var body: some View {
        let total = rules.reduce(Int64(0)) { $0 + $1.totalSize }
        let count = rules.flatMap(\.items).filter { !$0.reportOnly }.count
        let needsAccess = rules.filter { $0.status == .needsFullDiskAccess }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CheckboxButton(state: model.state(of: category), label: category.displayName) {
                    model.setSelected(model.state(of: category) != .on, category: category)
                }
                Text(category.displayName).font(.headline)
            }
            Text(formatBytes(total)).font(.title2.monospacedDigit())
            Text("\(count) item(s)").foregroundStyle(.secondary)
            if needsAccess > 0 {
                Label("\(needsAccess) rule(s) need Full Disk Access", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CleanupSummary: View {
    let report: RemovalReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Cleanup complete", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
            Text(
                "Freed \(formatBytes(report.deletedBytes)) now · \(formatBytes(report.quarantinedBytes)) in quarantine (see History to restore)."
            )
            if report.hadSkips {
                Text("\(report.skipped.count) item(s) were skipped; details are in History.").foregroundStyle(
                    .secondary)
            }
        }
    }
}
