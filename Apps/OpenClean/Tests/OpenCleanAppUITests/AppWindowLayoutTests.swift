import AppKit
import Foundation
import TestSupport
import Testing

/// End-to-end layout check of the real app window. The in-process tests host views in a hand-made `NSWindow`;
/// some bugs only appear in the SwiftUI scene's own window (on macOS 27 a sidebar ScrollView drew its rows
/// ~80 pt below where they were laid out and hit-tested, which a hand-made window does not reproduce). So this
/// launches the built app (`.build/debug/OpenCleanApp`, run `swift build` first) in layout-report mode on a
/// temporary home, then checks what it reports: rows laid out under the header, every click on a row's centre
/// selecting that row, and the selected row *drawn* where it was laid out.
@Suite(.serialized, .enabled(if: UIHarness.hasWindowServer, "needs a window server (GUI session)"))
struct AppWindowLayoutTests {
    struct Report: Decodable {
        var frames: [String: [Double]]
        var clicks: [String: String]
        var windowSize: [Double]
        var scale: Double

        func frame(_ id: String) -> CGRect? {
            guard let f = frames[id], f.count == 4 else { return nil }
            return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
        }
    }

    static let preferencesDomain = "OpenCleanLayoutCheck"
    static let modules = ["smartScan", "cleanup", "history", "uninstaller", "spaceLens", "performance"]
    static let allItems = modules + ["settings"]

    static var appBinary: URL {
        // Apps/OpenClean/Tests/OpenCleanAppUITests/<file> → the repo root.
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/OpenCleanApp")
    }

    /// Runs the app in layout-report mode against `home` and returns its report and window snapshot.
    func runApp(home: TempDirectory) throws -> (Report, NSBitmapImageRep) {
        let binary = Self.appBinary
        try #require(
            FileManager.default.isExecutableFile(atPath: binary.path), "build the app first: swift build")
        let rules = try FixtureRules.writeDirectory(in: home)
        let output = home.path + "/layout-report.json"

        // A bundle-less executable's preferences domain is its file name, and cfprefsd keeps it in the real
        // ~/Library/Preferences whatever HOME says. Running a copy under its own name keeps AppKit's window
        // autosave and the arguments below out of the developer's `OpenCleanApp` domain (what `swift run` uses);
        // that throwaway domain is cleared afterwards.
        let copy = home.url.appendingPathComponent(Self.preferencesDomain)
        try FileManager.default.copyItem(at: binary, to: copy)
        defer { UserDefaults.standard.removePersistentDomain(forName: Self.preferencesDomain) }

        let process = Process()
        process.executableURL = copy
        // OPENCLEAN_HOME (and HOME) point into the temp folder, so quarantine, settings and anything the app
        // scans stay there. No update check runs in report mode, and saved window state is ignored.
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["OPENCLEAN_HOME"] = home.path
        environment["OPENCLEAN_RULES_DIR"] = rules
        environment["OPENCLEAN_LAYOUT_REPORT"] = output
        process.environment = environment
        process.arguments = [
            "-onboarding.completedVersion", "1", "-menuBarMonitorEnabled", "NO", "-ApplePersistenceIgnoreState", "YES",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            process.terminate()
            Issue.record("the app did not finish its layout report within 60 s")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: output))
        let report = try JSONDecoder().decode(Report.self, from: data)
        let image = try #require(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: output + ".png"))))
        return (report, image)
    }

    @Test func realWindowSidebarIsLaidOutDrawnAndHitTestedTogether() throws {
        let home = try TempDirectory()
        let (report, image) = try runApp(home: home)

        // Laid out: rows in order, directly under the header.
        let header = try #require(report.frame("sidebar.header"))
        #expect(header.minY <= 60, "header starts \(header.minY) pt from the top")
        var previous = header
        for id in Self.modules {
            let row = try #require(report.frame("sidebar.\(id)"), "no frame for \(id)")
            let gap = row.minY - previous.maxY
            #expect(gap >= 0 && gap <= 10, "\(id) is \(gap) pt below the element above it")
            previous = row
        }

        // Hit-tested: a click on each row's laid-out centre selects that row.
        for id in Self.allItems {
            #expect(report.clicks[id] == id, "clicking \(id) selected \(report.clicks[id] ?? "nothing")")
        }

        // Drawn: the selected (Smart Scan) row's highlight is where it was laid out. Scan a column near the
        // row's trailing edge (clear of the icon and label) for the band brighter than the sidebar behind it.
        let row = try #require(report.frame("sidebar.smartScan"))
        let band = try #require(
            highlightBand(in: image, scale: report.scale, x: row.maxX - 12, from: header.minY, to: previous.maxY + 80),
            "no selected-row highlight found in the sidebar")
        #expect(abs(band.minY - row.minY) <= 4, "highlight drawn at \(band.minY) pt, laid out at \(row.minY) pt")
        #expect(abs(band.maxY - row.maxY) <= 4, "highlight ends at \(band.maxY) pt, laid out to \(row.maxY) pt")
    }

    /// The longest vertical run (in points, top-left origin) between `from` and `to` at `x` whose luminance is
    /// clearly above the column's median: the selected row's white fill over the dark sidebar.
    func highlightBand(in image: NSBitmapImageRep, scale: Double, x: Double, from: Double, to: Double) -> CGRect? {
        let px = Int(x * scale)
        let lo = max(0, Int(from * scale))
        let hi = min(image.pixelsHigh - 1, Int(to * scale))
        guard px >= 0, px < image.pixelsWide, lo < hi else { return nil }
        let luminance: [Double] = (lo...hi).map { y in
            guard let c = image.colorAt(x: px, y: y)?.usingColorSpace(.sRGB) else { return 0 }
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }
        let median = luminance.sorted()[luminance.count / 2]
        var best: Range<Int>?
        var start: Int?
        for i in 0...luminance.count {
            let value = i < luminance.count ? luminance[i] : -1
            if value > median + 0.06 {
                if start == nil { start = i }
            } else if let s = start {
                if (best?.count ?? 0) < i - s { best = s..<i }
                start = nil
            }
        }
        guard let best, Double(best.count) / scale >= 16 else { return nil }
        return CGRect(
            x: x, y: Double(lo + best.lowerBound) / scale, width: 1, height: Double(best.count) / scale)
    }
}
