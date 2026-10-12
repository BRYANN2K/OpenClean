import AppKit
import OpenCleanAppModel
import Permissions
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Quarantine") {
                Stepper("Keep removed files for \(model.retentionDays) days", value: $model.retentionDays, in: 1...90)
                Text("After this, quarantined files are deleted for good.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Rules") {
                Toggle("Show advanced (caution) rules", isOn: $model.advancedEnabled)
                LabeledContent("Your rule packs") {
                    Button("Reveal in Finder") { revealUserRules() }
                }
            }
            Section("Excluded locations") {
                ForEach(model.settings.excludedPaths, id: \.self) { path in
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Stop Excluding") { model.removeExclusion(path) }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder or File…") { addExclusion() }
            }
            Section("Full Disk Access") {
                LabeledContent("Status", value: model.accessAdvice == .ok ? "Granted" : "Not granted")
                Button("Open Privacy Settings") { NSWorkspace.shared.open(FullDiskAccessChecker.settingsURL) }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func addExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.addExclusion(url.path)
        }
    }

    private func revealUserRules() {
        try? FileManager.default.createDirectory(at: model.paths.userRules, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([model.paths.userRules])
    }
}
