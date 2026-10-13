import AppKit
import Foundation
import OpenCleanAppModel
import SwiftUI
import Testing

@testable import OpenCleanApp

/// Re-renders README screenshots from the harness: a temporary home filled with sample caches, the bundled
/// rule packs, fakes for everything else (no process is "running", Full Disk Access is granted, the disk is a
/// fixed 186 GB free of 494 GB). Nothing from the real home or the real Mac appears.
///
/// Off unless `OPENCLEAN_RECORD_SCREENSHOTS=<folder>` is set, like `OPENCLEAN_RECORD_GOLDEN`:
/// `OPENCLEAN_RECORD_SCREENSHOTS=$PWD/docs/screenshots swift test --filter ScreenshotRecorder`, then scale the
/// 2x render down with `sips --resampleWidth 1600` and review the image by hand.
@MainActor
@Suite(
    .serialized,
    .enabled(if: UIHarness.hasWindowServer, "needs a window server (GUI session)"),
    .enabled(if: ScreenshotOutput.folder != nil, "set OPENCLEAN_RECORD_SCREENSHOTS to record"))
struct ScreenshotRecorder {
    /// Sample files for the bundled rules, in KB. Sizes are small on purpose; only the layout matters.
    static let sampleFiles: [(String, Int)] = [
        ("Library/Caches/com.example.notely/Cache.db", 38_400),
        ("Library/Caches/com.example.pixelmate/thumbnails.db", 21_500),
        ("Library/Logs/Sketchpad/sketchpad.log", 6_200),
        ("Library/Developer/Xcode/DerivedData/Quill-abcdef/Build/Intermediates.noindex/quill.o", 96_000),
        ("Library/Developer/Xcode/Archives/2026-09-14/Quill 2.4.1.xcarchive/Info.plist", 41_000),
        (".npm/_cacache/content-v2/sha512/ab/cd/package.tgz", 52_000),
        ("Library/Caches/Yarn/v6/npm-left-pad-1.3.0/package.tgz", 18_300),
        ("Library/Caches/pip/http/a/b/c/wheel.whl", 12_700),
        (".cargo/registry/cache/index.crates.io/serde-1.0.200.crate", 9_800),
        (".gradle/caches/modules-2/files-2.1/okhttp-4.12.0.jar", 22_400),
        (".Trash/Old Invoice Template.pages", 15_300),
    ]

    @Test func cleanup() async throws {
        let output = try #require(ScreenshotOutput.folder)
        let harness = try UIHarness(rulesDirectory: UIHarness.bundledRules, probes: EmptyProbes.all)
        defer { harness.tearDown() }
        for (path, kilobytes) in Self.sampleFiles {
            try harness.home.file(path, bytes: kilobytes * 1_024, modified: Date().addingTimeInterval(-86_400 * 60))
        }
        harness.model.onLaunch()
        harness.model.startScan()
        await harness.model.waitForScan()
        #expect(harness.model.phase == .results)

        harness.navigation.selection = .cleanup
        let window = harness.host(ContentView(), size: CGSize(width: 1280, height: 800))
        let developer = try #require(harness.frame("cleanup.category.developer"), "no Developer Tools row")
        window.makeKey()
        harness.settle(0.2)
        harness.click(window, at: CGPoint(x: developer.maxX - 60, y: developer.midY))
        harness.settle(0.6)
        try snapshot(window, to: output + "/cleanup.png")
    }

    func snapshot(_ window: NSWindow, to path: String) throws {
        let content = try #require(window.contentView)
        let rep = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }
}

enum ScreenshotOutput {
    /// `OPENCLEAN_RECORD_SCREENSHOTS`, when it is an absolute path.
    static var folder: String? {
        ProcessInfo.processInfo.environment["OPENCLEAN_RECORD_SCREENSHOTS"].flatMap { $0.hasPrefix("/") ? $0 : nil }
    }
}
