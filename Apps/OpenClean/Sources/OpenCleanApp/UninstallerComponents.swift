import AppInventory
import AppKit
import SwiftUI

/// The app's own Finder icon, loaded lazily. Decorative: the name is always next to it.
struct UninstallerAppIcon: View {
    let path: String
    var size: CGFloat = 32
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Theme.glassFill)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: path) { image = NSWorkspace.shared.icon(forFile: path) }
    }
}

/// A small worded label in the style of `SafetyTag`; the text always carries the meaning.
struct UninstallerTag: View {
    let text: String
    var tint: Color = Theme.textSecondary

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.glassFill, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.glassStroke))
    }
}

extension InstalledApp {
    /// Short state shown in the app list; nil for an ordinary, removable app.
    var stateLabel: (text: String, tint: Color)? {
        switch status {
        case .removable: isRunning ? (String(localized: "Running"), Theme.gold) : nil
        case .appleApp: (String(localized: "Apple app"), Theme.textTertiary)
        case .openClean: ("OpenClean", Theme.textTertiary)
        case .needsAdministrator:
            isRunning ? (String(localized: "Running"), Theme.gold) : (String(localized: "Needs password"), Theme.gold)
        case .listOnly: (String(localized: "Utilities"), Theme.textTertiary)
        case .noBundleID: (String(localized: "No bundle ID"), Theme.textTertiary)
        }
    }
}

extension Leftover {
    var matchLabel: (text: String, tint: Color) {
        switch match {
        case .bundleID: (String(localized: "Matches bundle ID"), Theme.textSecondary)
        case .name: (String(localized: "Matches name"), Theme.gold)
        }
    }

    var displayName: String { (path as NSString).lastPathComponent }
    var displayFolder: String { ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }
}

/// "Today, 5:13 PM", "Yesterday, 9:02 AM", otherwise "Mar 4, 2025". Never a numeric date.
func uninstallerDateText(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return String(localized: "Today, \(time)") }
    if calendar.isDateInYesterday(date) { return String(localized: "Yesterday, \(time)") }
    return date.formatted(.dateTime.month(.abbreviated).day().year())
}

/// "1 leftover", "3 leftovers".
func leftoverCount(_ count: Int) -> String {
    String(localized: "\(count) leftovers")
}
