import AppKit
import OpenCleanAppModel
import SwiftUI
import SystemMonitor

enum MenuBarSettings {
    static let enabledKey = "menuBarMonitorEnabled"
    static let metricKey = "menuBarMetric"
    static let mainWindowID = "main"
}

/// The status item: the logo glyph as a template image plus, optionally, one live figure.
/// Samples only while a figure is shown (or the popover is open).
struct MenuBarLabel: View {
    @Environment(PerformanceModel.self) private var model
    @AppStorage(MenuBarSettings.metricKey) private var metricRaw = MenuBarMetric.cpu.rawValue

    var body: some View {
        let metric = MenuBarMetric(rawValue: metricRaw) ?? .cpu
        HStack(spacing: 4) {
            Image(nsImage: MenuBarGlyph.image)
            if metric != .none {
                Text(text(for: metric)).monospacedDigit()
            }
        }
        .accessibilityLabel("OpenClean, \(metric == .none ? "monitor" : text(for: metric))")
        .task(id: metricRaw) {
            guard metric != .none else { return }
            await model.monitor(.metrics)
        }
    }

    private func text(for metric: MenuBarMetric) -> String {
        switch metric {
        case .none: ""
        case .cpu: formatPercent(model.cpu)
        case .memory: formatPercent(model.memory?.usedFraction)
        case .network: "↓" + formatRate(model.network?.receivedPerSecond)
        }
    }
}

/// The window-style popover: live figures, the top three apps and two ways into the main window.
struct MenuBarPopover: View {
    @Environment(PerformanceModel.self) private var model
    @Environment(AppModel.self) private var app
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                AppIconView(size: 22)
                Wordmark(size: 15)
                Spacer()
            }

            VStack(spacing: 10) {
                meterRow("CPU", value: formatPercent(model.cpu), fraction: model.cpu ?? 0)
                meterRow(
                    "Memory",
                    value: model.memory.map { "\(formatBytes(Int64($0.used))) · \(pressureLabel($0.pressure))" } ?? "–",
                    fraction: model.memory?.usedFraction ?? 0,
                    color: model.memory.map { pressureColor($0.pressure) } ?? Theme.accent)
                meterRow(
                    "Disk", value: model.disk.map { "\(formatCapacity($0.available)) free" } ?? "–",
                    fraction: model.disk?.usedFraction ?? 0)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Network").foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(
                            "↓ \(formatRate(model.network?.receivedPerSecond))  ↑ \(formatRate(model.network?.sentPerSecond))"
                        )
                        .monospacedDigit()
                    }
                    Sparkline(points: model.receivedHistory).frame(height: 24)
                }
                .accessibilityElement(children: .combine)
            }
            .font(.system(size: 12))
            .padding(12)
            .glassPanel(radius: 12)

            VStack(alignment: .leading, spacing: 8) {
                Text("Heavy apps").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                let top = model.topByCPU(3)
                if top.isEmpty {
                    Text("Measuring…").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                ForEach(top) { group in
                    HStack(spacing: 8) {
                        ProcessIcon(bundlePath: group.bundlePath, size: 18)
                        Text(group.name).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.0f%%", group.cpuPercent)).monospacedDigit()
                        Text(formatBytes(Int64(group.residentBytes)))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                            .frame(minWidth: 64, alignment: .trailing)
                    }
                    .font(.system(size: 12))
                    .accessibilityElement(children: .combine)
                }
            }

            HStack(spacing: 8) {
                Button("Open OpenClean") { showMainWindow() }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                Button("Smart Scan") {
                    navigation.selection = .smartScan
                    showMainWindow()
                    // Never throw away results the user hasn't acted on, or interrupt a cleanup.
                    if app.phase == .idle || app.phase == .finished { app.startScan() }
                }
                .buttonStyle(CapsuleButtonStyle())
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(16)
        .frame(width: 320)
        .background(Backdrop.performance.gradient)
        .preferredColorScheme(.dark)
        .task { await model.monitor([.metrics, .processes]) }
    }

    private func meterRow(_ title: String, value: String, fraction: Double, color: Color = Theme.accent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(value).monospacedDigit().lineLimit(1)
            }
            MeterBar(fraction: fraction, color: color)
        }
        .accessibilityElement(children: .combine)
    }

    /// Brings the existing main window forward, or opens one if it was closed.
    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix(MenuBarSettings.mainWindowID) == true && $0.canBecomeMain
        }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: MenuBarSettings.mainWindowID)
        }
    }
}
