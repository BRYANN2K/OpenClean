import AppKit
import Foundation
import OpenCleanAppModel
import SwiftUI
import Testing

@testable import OpenCleanApp

/// Every main screen, in its interesting states, renders in the app's window without crashing and fills the
/// detail column. The models run on a temporary home with fakes, so nothing touches the real home.
@MainActor
@Suite(.serialized, .enabled(if: UIHarness.hasWindowServer, "needs a window server (GUI session)"))
struct ScreenRenderTests {
    /// Hosts the main window on `item` and checks the screen was laid out across the detail column.
    @discardableResult
    func show(_ item: SidebarItem, in harness: UIHarness, size: CGSize = CGSize(width: 1200, height: 760))
        throws -> NSWindow
    {
        harness.navigation.selection = item
        let window = harness.host(ContentView(), size: size)
        let screen = try #require(harness.frame("screen.\(item.rawValue)"), "\(item) was never laid out")
        let sidebar = try #require(harness.frame("sidebar.smartScan"))
        #expect(screen.minX >= sidebar.maxX, "\(item) overlaps the sidebar")
        #expect(screen.width >= size.width - 300, "\(item) is only \(screen.width) pt wide")
        #expect(screen.maxX <= size.width + 0.5)
        #expect(screen.height >= size.height - 60, "\(item) is only \(screen.height) pt tall")
        return window
    }

    @Test(arguments: SidebarItem.allCases)
    func everyScreenRendersOnAFreshLaunch(item: SidebarItem) throws {
        let harness = try UIHarness()
        defer { harness.tearDown() }
        harness.model.onLaunch()
        try show(item, in: harness)
    }

    @Test func smartScanResultsAndCleanupRender() async throws {
        let harness = try UIHarness()
        defer { harness.tearDown() }
        try harness.home.file("Library/Caches/com.example.editor/cache.db", bytes: 64_000)
        try harness.home.file("Downloads/installer.dmg", bytes: 32_000)
        harness.model.onLaunch()
        harness.model.startScan()
        await harness.model.waitForScan()
        #expect(harness.model.phase == .results)

        try show(.smartScan, in: harness)
        harness.tearDown()
        try show(.cleanup, in: harness)
    }

    @Test func finishedCleanupAndHistoryRender() async throws {
        let harness = try UIHarness()
        defer { harness.tearDown() }
        let download = try harness.home.file("Downloads/old-installer.dmg", bytes: 16_000)
        harness.model.onLaunch()
        harness.model.startScan()
        await harness.model.waitForScan()
        harness.model.selectedPaths = [download]
        await harness.model.clean()
        #expect(harness.model.phase == .finished)
        #expect(harness.model.history.count == 1)

        try show(.smartScan, in: harness)
        harness.tearDown()
        try show(.history, in: harness)
    }

    @Test func uninstallerListAndDetailRender() async throws {
        let harness = try UIHarness()
        defer { harness.tearDown() }
        let contents = try harness.home.directory("Applications/Sample Editor.app/Contents")
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.editor", "CFBundleName": "Sample Editor"],
            format: .xml, options: 0
        )
        .write(to: URL(fileURLWithPath: contents + "/Info.plist"))
        try harness.home.file("Applications/Sample Editor.app/Contents/MacOS/editor", bytes: 4_096)
        try harness.home.directory("Library/Application Support/com.example.editor")

        harness.uninstaller.onAppear()
        await harness.uninstaller.waitForLoad()
        let app = try #require(harness.uninstaller.apps.first)
        try show(.uninstaller, in: harness)
        harness.uninstaller.select(app)
        await harness.uninstaller.waitForLeftovers()
        harness.settle()
        #expect(harness.frame("screen.uninstaller") != nil)
    }

    @Test func spaceLensMapRenders() async throws {
        let harness = try UIHarness()
        defer { harness.tearDown() }
        try harness.home.file("Movies/clip.mov", bytes: 200_000)
        try harness.home.file("Documents/notes.txt", bytes: 10_000)
        harness.spaceLens.startMapScan()
        await harness.spaceLens.waitForScan(.map)
        #expect(harness.spaceLens.mapResult != nil)
        try show(.spaceLens, in: harness)
    }

    @Test func screensRenderAtALargeWindowSize() throws {
        let harness = try UIHarness()
        defer { harness.tearDown() }
        harness.model.onLaunch()
        for item in SidebarItem.allCases {
            try show(item, in: harness, size: CGSize(width: 1680, height: 1050))
            harness.tearDown()
        }
    }

    @Test func onboardingMenuBarAndSheetsRender() throws {
        let harness = try UIHarness()
        defer { harness.tearDown() }
        harness.model.onLaunch()
        let onboarding = harness.host(OnboardingView())
        #expect(onboarding.contentView?.fittingSize != nil)
        let popover = harness.host(MenuBarPopover(), size: CGSize(width: 360, height: 520))
        #expect(popover.contentView?.subviews.isEmpty == false)
        harness.host(ReviewSheet(), size: CGSize(width: 720, height: 560))
        harness.host(SoftwareUpdateSheet(), size: CGSize(width: 520, height: 420))
    }
}
