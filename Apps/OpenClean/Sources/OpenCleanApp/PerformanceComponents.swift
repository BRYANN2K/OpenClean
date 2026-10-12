import AppKit
import Charts
import OpenCleanAppModel
import SwiftUI
import SystemMonitor

// Small building blocks shared by the Performance screens and the menu bar popover.

func formatPercent(_ fraction: Double?) -> String {
    guard let fraction else { return "–" }
    return "\(Int((fraction * 100).rounded()))%"
}

/// "1.2 MB/s", "340 KB/s", "0 KB/s".
func formatRate(_ bytesPerSecond: Double?) -> String {
    guard let bytesPerSecond else { return "–" }
    if bytesPerSecond < 1_000 { return "0 KB/s" }
    return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
}

/// "Today, 5:13 PM", "Yesterday, 9:02 AM", otherwise "Mar 4, 5:13 PM" (same style as History).
func formatRelativeDay(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today, \(time)" }
    if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
    return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
}

func pressureLabel(_ pressure: MemoryPressure) -> String {
    switch pressure {
    case .normal: "Normal"
    case .warning: "Elevated"
    case .critical: "High"
    case .unknown: "Unknown"
    }
}

func pressureColor(_ pressure: MemoryPressure) -> Color {
    switch pressure {
    case .normal, .unknown: Theme.accent
    case .warning: Theme.gold
    case .critical: Theme.coral
    }
}

/// A word in a small capsule, like `SafetyTag`: "Needs admin", "System (read-only)". Never color alone.
struct StatusTag: View {
    let text: String
    var color: Color = Theme.textSecondary

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.glassFill, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.glassStroke))
            .lineLimit(1)
            .fixedSize()
    }
}

/// A tiny line + area chart of recent values. Decorative: the number next to it carries the meaning.
struct Sparkline: View {
    let points: [MetricPoint]
    /// Fixed upper bound (e.g. 1 for fractions); nil scales to the data.
    var maxValue: Double?
    var color: Color = Theme.accent

    var body: some View {
        let top = max(maxValue ?? (points.map(\.value).max() ?? 0), maxValue == nil ? 1 : 0.0001)
        Chart(points) { point in
            AreaMark(x: .value("Sample", point.id), y: .value("Value", min(point.value, top)))
                .foregroundStyle(color.opacity(0.22))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Sample", point.id), y: .value("Value", min(point.value, top)))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: 0...top)
        .chartXScale(domain: .automatic(includesZero: false))
        .accessibilityHidden(true)
    }
}

/// A thin horizontal meter (0…1) for the menu bar popover.
struct MeterBar: View {
    let fraction: Double
    var color: Color = Theme.accent

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.glassStroke)
                Capsule().fill(color)
                    .frame(width: max(4, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

/// App icon for a bundle path, or an SF Symbol tile for bundle-less processes.
struct ProcessIcon: View {
    let bundlePath: String?
    var size: CGFloat = 28

    var body: some View {
        if let bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
                .resizable()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(Theme.glassFill)
                .overlay(
                    Image(systemName: "terminal")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                )
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

/// The "back" link at the top left of sub-screens.
struct BackLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "chevron.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }
}

/// Renders the logo glyph as a monochrome template image for the menu bar.
@MainActor
enum MenuBarGlyph {
    static let image: NSImage = {
        let renderer = ImageRenderer(content: LogoGlyph(size: 18).frame(width: 18, height: 18))
        renderer.scale = 2
        let image =
            renderer.nsImage ?? NSImage(
                systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil) ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "OpenClean"
        return image
    }()
}
