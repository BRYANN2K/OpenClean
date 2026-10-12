import AppKit
import OpenCleanAppModel
import SwiftUI
import SystemMonitor

/// Quit and Force Quit go only through `NSRunningApplication`, and only for groups the library's
/// `ForceQuitPolicy` allows, whose running app still matches the bundle we sampled.
@MainActor
enum AppQuitter {
    static func runningApp(for group: ProcessGroup) -> NSRunningApplication? {
        guard group.canQuit, let pid = group.mainPID, let bundlePath = group.bundlePath,
            pid != ProcessInfo.processInfo.processIdentifier,
            let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
            let bundleURL = app.bundleURL,
            bundleURL.resolvingSymlinksInPath().path == URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().path
        else { return nil }
        return app
    }
}

struct HeavyConsumersView: View {
    @Environment(PerformanceModel.self) private var model
    @State private var sortByMemory = false
    @State private var forceQuitTarget: ProcessGroup?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Sort by", selection: $sortByMemory) {
                    Text("CPU").tag(false)
                    Text("Memory").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                Spacer()
                if let notice {
                    Text(notice).font(.system(size: 12)).foregroundStyle(Theme.gold).lineLimit(1)
                }
            }
            if groups.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(40)
                .glassPanel()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(groups) { group in
                            ConsumerRow(group: group, onQuit: { quit(group) }, onForceQuit: { forceQuitTarget = group })
                            if group.id != groups.last?.id { Divider().overlay(Theme.glassDivider) }
                        }
                    }
                    .glassPanel()
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
            }
            Text(
                "Only your own processes can be measured without administrator rights. System processes are never offered Quit."
            )
            .font(.system(size: 12))
            .foregroundStyle(Theme.textTertiary)
            .padding(.bottom, 16)
        }
        .task { await model.monitor([.metrics, .processes]) }
        .sheet(item: $forceQuitTarget) { group in
            ForceQuitSheet(group: group) {
                forceQuit(group)
                forceQuitTarget = nil
            } onCancel: {
                forceQuitTarget = nil
            }
        }
    }

    private var groups: [ProcessGroup] {
        sortByMemory ? model.topByMemory(25) : model.topByCPU(25)
    }

    private func quit(_ group: ProcessGroup) {
        guard let app = AppQuitter.runningApp(for: group) else {
            notice = "\(group.name) can't be quit from OpenClean."
            return
        }
        notice = app.terminate() ? "Asked \(group.name) to quit." : "\(group.name) didn't accept the request to quit."
    }

    private func forceQuit(_ group: ProcessGroup) {
        guard let app = AppQuitter.runningApp(for: group) else {
            notice = "\(group.name) can't be force quit from OpenClean."
            return
        }
        notice = app.forceTerminate() ? "\(group.name) was force quit." : "\(group.name) could not be force quit."
    }
}

struct ConsumerRow: View {
    let group: ProcessGroup
    let onQuit: () -> Void
    let onForceQuit: () -> Void

    var body: some View {
        let quittable = AppQuitter.runningApp(for: group) != nil
        HStack(spacing: 14) {
            ProcessIcon(bundlePath: group.bundlePath, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(String(format: "%.1f%%", group.cpuPercent))
                .font(.system(size: 14))
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
                .accessibilityLabel("CPU \(Int(group.cpuPercent.rounded())) percent")
            Text(formatBytes(Int64(group.residentBytes)))
                .font(.system(size: 14))
                .monospacedDigit()
                .frame(minWidth: 84, alignment: .trailing)
                .accessibilityLabel("Memory \(formatBytes(Int64(group.residentBytes)))")
            if quittable {
                Button("Quit", action: onQuit).buttonStyle(CapsuleButtonStyle()).fixedSize()
                Button("Force Quit…", action: onForceQuit).buttonStyle(CapsuleButtonStyle()).fixedSize()
            } else {
                StatusTag(text: group.bundlePath == nil ? "Process" : "Protected")
                    .frame(minWidth: 190, alignment: .trailing)
                    .help("OpenClean only offers Quit for apps, never for macOS components or itself.")
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 56)
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        let count = group.processes.count
        return count == 1 ? (group.processes.first?.name ?? "") : "\(count) processes"
    }
}

struct ForceQuitSheet: View {
    let group: ProcessGroup
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProcessIcon(bundlePath: group.bundlePath, size: 40)
                Text("Force quit \(group.name)?").font(.title2.bold())
            }
            Text(
                "Force quitting stops the app immediately. Anything you haven’t saved in it will be lost. Try Quit first if the app is still responding."
            )
            .foregroundStyle(.secondary)
            .lineLimit(4)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Force Quit", role: .destructive, action: onConfirm).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
