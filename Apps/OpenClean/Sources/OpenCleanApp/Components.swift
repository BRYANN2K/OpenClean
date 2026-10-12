import AppKit
import OpenCleanAppModel
import Permissions
import RuleKit
import SwiftUI

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// A tri-state checkbox that announces its state to VoiceOver.
struct CheckboxButton: View {
    let state: AppModel.CheckState
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
                .imageScale(.large)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(state == .on ? "selected" : state == .mixed ? "partially selected" : "not selected")
    }

    private var symbol: String {
        switch state {
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        case .off: "square"
        }
    }
}

struct SafetyBadge: View {
    let safety: SafetyLevel

    var body: some View {
        Text(safety.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("Safety: \(safety.rawValue)")
    }

    private var color: Color {
        switch safety {
        case .regenerable: .green
        case .review: .orange
        case .caution: .red
        }
    }
}

struct AccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.accessAdvice != .ok {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Settings") { NSWorkspace.shared.open(FullDiskAccessChecker.settingsURL) }
                Button("Check Again") { model.refreshAccess() }
            }
            .padding(12)
            .background(Color.yellow.opacity(0.15))
        }
    }

    private var title: String {
        model.accessAdvice == .regrantAfterRebuild
            ? "Full Disk Access needs to be granted again" : "Full Disk Access is off"
    }

    private var message: String {
        model.accessAdvice == .regrantAfterRebuild
            ? "This build of OpenClean has a new signature, so macOS no longer recognises the earlier permission. Remove OpenClean from the list in Settings, add it again, then click Check Again."
            : "Trash, Mail, Safari and iOS backups can only be scanned with Full Disk Access."
    }
}

struct ProblemsBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.loadedRules.problems.isEmpty {
            DisclosureGroup {
                ForEach(model.loadedRules.problems, id: \.self) { problem in
                    Text(problem).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } label: {
                Label("Some rule packs were skipped", systemImage: "exclamationmark.triangle")
            }
            .padding(12)
            .background(Color.orange.opacity(0.12))
        }
    }
}

struct ComingSoonView: View {
    var body: some View {
        ContentUnavailableView(
            "Coming soon", systemImage: "hammer",
            description: Text("This module is planned for a later OpenClean release."))
    }
}
