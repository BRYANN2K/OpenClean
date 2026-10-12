import AppKit
import OpenCleanAppModel
import Permissions
import RuleKit
import SwiftUI

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Disk capacities without false precision: "160 GB" rather than "160.17 GB".
func formatCapacity(_ bytes: Int64) -> String {
    let gigabytes = Double(bytes) / 1_000_000_000
    if gigabytes >= 1_000 { return String(format: "%.1f TB", gigabytes / 1_000) }
    if gigabytes >= 10 { return "\(Int(gigabytes.rounded())) GB" }
    return formatBytes(bytes)
}

/// A tri-state checkbox that announces its state to VoiceOver.
struct CheckboxButton: View {
    let state: AppModel.CheckState
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(state == .off ? Color.clear : Theme.accent)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(state == .off ? Color.white : Theme.accent, lineWidth: 1.5)
                )
                .overlay {
                    if state != .off {
                        Image(systemName: state == .on ? "checkmark" : "minus")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(Theme.deepTeal)
                    }
                }
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(state == .on ? "selected" : state == .mixed ? "partially selected" : "not selected")
    }
}

/// Free space and what OpenClean has freed, at the bottom of the sidebar.
struct StorageCard: View {
    let disk: DiskSpace?
    let stats: CleanupStats

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let disk {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(formatCapacity(disk.available)) free").font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("of \(formatCapacity(disk.total))")
                        .lineLimit(1)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                .monospacedDigit()
                ProgressView(value: disk.freeFraction)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
            }
            Text(caption).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
        .foregroundStyle(.white)
        .padding(12)
        .glassPanel(radius: 12)
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        stats.cleanups == 0
            ? "Nothing cleaned yet" : "\(formatBytes(stats.totalFreedBytes)) freed by OpenClean"
    }
}

struct AccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.accessAdvice != .ok {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(Theme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    // No fixedSize here: measured at minimum width it would inflate the window's minimum height.
                    Text(message).font(.callout).foregroundStyle(Theme.textSecondary).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Open Settings") { NSWorkspace.shared.open(FullDiskAccessChecker.settingsURL) }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .fixedSize()
                Button("Check Again") { model.refreshAccess() }
                    .buttonStyle(CapsuleButtonStyle())
                    .fixedSize()
            }
            .foregroundStyle(.white)
            .padding(14)
            .glassPanel(radius: 14)
            .padding([.horizontal, .top], 16)
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
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } label: {
                Label("Some rule packs were skipped", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.gold)
            }
            .padding(14)
            .glassPanel(radius: 14)
            .padding([.horizontal, .top], 16)
        }
    }
}

struct ComingSoonView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "hammer.fill").font(.system(size: 44)).foregroundStyle(Theme.textSecondary)
            Text("Coming soon").font(.system(size: 28, weight: .bold))
            Text("This module is planned for a later OpenClean release.")
                .foregroundStyle(Theme.textSecondary)
        }
        .foregroundStyle(.white)
    }
}
