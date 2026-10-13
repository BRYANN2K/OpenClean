import AppKit
import SwiftUI

/// Layout self-check for the UI tests (`OPENCLEAN_LAYOUT_REPORT=<path>`). The tests launch the real app, because
/// only the real SwiftUI scene window reproduces some bugs (on macOS 27 a sidebar ScrollView drew its rows
/// ~80 pt below where SwiftUI laid them out and hit-tested them). In this mode the app, with an invisible window:
/// clicks the centre of every sidebar row as laid out and records which section each click selected, renders
/// the window with Smart Scan selected to `<path>.png`, writes the laid-out frames and click results to `<path>`
/// as JSON, and quits. Without the variable none of this exists: the probe is nil and `.layoutProbe` adds nothing.
@MainActor
enum LayoutReport {
    static let environmentKey = "OPENCLEAN_LAYOUT_REPORT"

    static var outputPath: String? {
        guard let path = ProcessInfo.processInfo.environment[environmentKey], path.hasPrefix("/") else { return nil }
        return path
    }

    struct Report: Codable {
        /// Laid-out frames in window points, top-left origin, keyed by probe id.
        var frames: [String: [Double]]
        /// For each sidebar item: the item the click at its laid-out centre selected ("" = none).
        var clicks: [String: String]
        /// Window content size in points, and the snapshot's pixels per point.
        var windowSize: [Double]
        var scale: Double
    }

    static func run(output: String, probe: LayoutProbe, navigation: AppNavigation) async {
        defer { NSApp.terminate(nil) }
        try? await Task.sleep(for: .seconds(1))
        // The main window: the only one at least as wide as its 1200 pt minimum (the menu bar extra is small).
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width >= 1000 }),
            let content = window.contentView
        else { return }
        window.alphaValue = 0

        var clicks: [String: String] = [:]
        // Bottom-up, so every click changes the selection (Smart Scan starts selected).
        for item in SidebarItem.allCases.reversed() {
            guard let frame = probe.frames["sidebar.\(item.rawValue)"] else { continue }
            navigation.selection = item == .smartScan ? .history : .smartScan
            try? await Task.sleep(for: .milliseconds(150))
            let point = NSPoint(x: frame.midX, y: content.bounds.height - frame.midY)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                {
                    window.sendEvent(event)
                }
            }
            try? await Task.sleep(for: .milliseconds(150))
            clicks[item.rawValue] = navigation.selection?.rawValue ?? ""
        }

        navigation.selection = .smartScan
        try? await Task.sleep(for: .milliseconds(500))
        var scale = 1.0
        if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            scale = Double(rep.pixelsWide) / Double(content.bounds.width)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output + ".png"))
        }
        let report = Report(
            frames: probe.frames.mapValues { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) },
            clicks: clicks, windowSize: [content.bounds.width, content.bounds.height].map(Double.init), scale: scale)
        try? JSONEncoder().encode(report).write(to: URL(fileURLWithPath: output))
    }
}
