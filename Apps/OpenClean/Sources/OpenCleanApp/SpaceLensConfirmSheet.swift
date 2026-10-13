import OpenCleanAppModel
import SwiftUI

/// Lists every ticked item before anything moves. No removal path in Space Lens bypasses it.
struct SpaceLensConfirmSheet: View {
    @Environment(SpaceLensModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let items = model.selectedCandidates
        VStack(alignment: .leading, spacing: 16) {
            Text("Move \(items.count) items to the Trash?").font(.title2.bold())
            Text("\(formatBytes(model.selectedBytes)) in total. You can put items back from the Trash in Finder.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        HStack(spacing: 10) {
                            FileIcon(path: item.path, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                Text(spaceLensFolder(item.path, home: model.home))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if item.isUserContent {
                                Text(userContentLabel(item.path, home: model.home))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            } else if item.isDirectory {
                                Text("Folder").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            Text(formatBytes(item.size)).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            if items.contains(where: \.isUserContent) {
                Label(
                    "Files from Documents or Desktop are moved only because you ticked each one.",
                    systemImage: "hand.tap")
            }
            Text("Items that changed since the scan, are open in another app, or are protected are left in place.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                if model.isTrashing {
                    ProgressView().controlSize(.small)
                    Text("Moving…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isTrashing)
                Button("Move to Trash") {
                    Task { await model.confirmTrash() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(items.isEmpty || model.isTrashing)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
