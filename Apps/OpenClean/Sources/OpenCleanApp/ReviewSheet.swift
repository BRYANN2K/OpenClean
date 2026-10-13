import OpenCleanAppModel
import SwiftUI

struct ReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review cleanup").font(.title2.bold())
            if let plan = model.plan {
                LabeledContent(
                    "Deleted now",
                    value:
                        "\(formatBytes(plan.immediateBytes)) · \(String(localized: "\(plan.immediateRequests.count) items"))"
                )
                LabeledContent(
                    "Moved to quarantine (restorable for \(model.settings.clampedRetentionDays) days)",
                    value:
                        "\(formatBytes(plan.quarantineBytes)) · \(String(localized: "\(plan.quarantineRequests.count) items"))"
                )
                if !plan.adminRequests.isEmpty {
                    Label(
                        "\(plan.adminRequests.count) system items need your administrator password.",
                        systemImage: "lock.shield")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(plan.adminRequests.map(\.item.path), id: \.self) { path in
                                Text(path)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                Text("Files that changed since the scan, or are open in another app, are skipped automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Clean") {
                    dismiss()
                    Task { await model.clean() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.plan?.isEmpty ?? true)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
