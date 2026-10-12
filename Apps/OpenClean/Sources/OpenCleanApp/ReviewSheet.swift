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
                    "Deleted now", value: "\(formatBytes(plan.immediateBytes)) · \(plan.immediateRequests.count) item(s)")
                LabeledContent(
                    "Moved to quarantine (restorable for \(model.settings.clampedRetentionDays) days)",
                    value: "\(formatBytes(plan.quarantineBytes)) · \(plan.quarantineRequests.count) item(s)")
                if !plan.adminRequests.isEmpty {
                    Label(
                        "\(plan.adminRequests.count) system item(s) need your administrator password.",
                        systemImage: "lock.shield")
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
