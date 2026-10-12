import AppKit
import OpenCleanAppModel
import Quarantine
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var pending: PendingRestore?
    @State private var isAsking = false
    @State private var lastRestore: RestoreReport?

    struct PendingRestore {
        let sessionID: String
        let paths: Set<String>?
    }

    var body: some View {
        List {
            if let lastRestore {
                Label(
                    "Restored \(lastRestore.restored.count) item(s), skipped \(lastRestore.skipped.count).",
                    systemImage: "arrow.uturn.backward.circle")
            }
            if model.history.isEmpty {
                ContentUnavailableView("No cleanups yet", systemImage: "clock")
            }
            ForEach(model.history) { listing in
                switch listing {
                case .ok(let manifest):
                    SessionRow(manifest: manifest) { paths in
                        pending = PendingRestore(sessionID: manifest.id, paths: paths)
                        isAsking = true
                    }
                case .damaged(let id, _):
                    HStack {
                        Label("Damaged session \(id)", systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([model.paths.quarantine.appendingPathComponent(id)])
                        }
                    }
                }
            }
        }
        .onAppear { model.refreshHistory() }
        .confirmationDialog("If a file already exists at the original location:", isPresented: $isAsking) {
            Button("Skip It") { restore(.skip) }
            Button("Keep Both") { restore(.keepBoth) }
            Button("Replace It (old one goes to Trash)") { restore(.replace) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func restore(_ policy: ConflictPolicy) {
        guard let pending else { return }
        Task { lastRestore = await model.restore(sessionID: pending.sessionID, paths: pending.paths, onConflict: policy) }
    }
}

struct SessionRow: View {
    let manifest: SessionManifest
    let onRestore: (Set<String>?) -> Void

    var body: some View {
        let restorable = Set(manifest.restorableEntries.map(\.id))
        DisclosureGroup {
            ForEach(manifest.entries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.originalPath).lineLimit(1).truncationMode(.middle)
                        Text([entry.outcome.rawValue.capitalized, entry.reason].compactMap { $0 }.joined(separator: " — "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formatBytes(entry.size)).monospacedDigit().foregroundStyle(.secondary)
                    if manifest.purgedAt == nil && restorable.contains(entry.id) {
                        Button("Restore") { onRestore([entry.originalPath]) }
                    }
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.createdAt, format: .dateTime).font(.headline)
                    Text(
                        "Freed \(formatBytes(manifest.deletedBytes)) · Quarantined \(formatBytes(manifest.quarantinedBytes)) · Skipped \(manifest.skippedEntries.count)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if manifest.purgedAt != nil {
                    Text("Purged").foregroundStyle(.secondary)
                } else if !restorable.isEmpty {
                    Button("Restore All") { onRestore(nil) }
                }
            }
        }
    }
}
