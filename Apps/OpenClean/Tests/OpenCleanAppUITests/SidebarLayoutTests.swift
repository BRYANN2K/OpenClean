import AppKit
import SwiftUI
import Testing

@testable import OpenCleanApp

/// Sidebar geometry and hit-testing in a window shaped like the app's, at its minimum and a large size: rows
/// in order directly under the header, inside the sidebar column, Settings pinned to the bottom, and a click
/// anywhere inside a row's laid-out frame selecting that row. (The macOS 27 ScrollView regression, rows drawn
/// ~80 pt below their hit areas, only shows in the real scene window; `AppWindowLayoutTests` covers it.)
@MainActor
@Suite(.serialized, .enabled(if: UIHarness.hasWindowServer, "needs a window server (GUI session)"))
struct SidebarLayoutTests {
    nonisolated static let sizes = [CGSize(width: 1200, height: 720), CGSize(width: 1600, height: 1000)]

    @Test(arguments: sizes)
    func rowsSitInOrderJustUnderTheHeader(size: CGSize) throws {
        let harness = try UIHarness()
        defer { harness.tearDown() }
        harness.model.onLaunch()
        harness.host(ContentView(), size: size)

        let header = try #require(harness.frame("sidebar.header"))
        let detail = try #require(harness.frame("detail"))
        // The header (logo + wordmark) sits at the top, under the window buttons, not pushed down.
        #expect(header.minY >= 0)
        #expect(header.minY <= 60, "header starts \(header.minY) pt from the top")

        var previous = header
        for item in SidebarItem.modules {
            let row = try #require(harness.frame("sidebar.\(item.rawValue)"), "no frame for \(item)")
            #expect(row.height >= 28 && row.height <= 40, "\(item) is \(row.height) pt tall")
            // Each row directly follows the one above it (the first follows the header): ordered, no gap.
            let gap = row.minY - previous.maxY
            #expect(gap >= 0 && gap <= 10, "\(item) is \(gap) pt below the element above it")
            // Inside the sidebar column, not under the detail area.
            #expect(row.minX >= 0 && row.maxX <= detail.minX, "\(item) at \(row) overlaps the detail column")
            previous = row
        }

        // Storage card and Settings are pinned to the bottom of the sidebar, inside the window.
        let storage = try #require(harness.frame("sidebar.storage"))
        let settings = try #require(harness.frame("sidebar.settings"))
        #expect(storage.minY > previous.maxY)
        #expect(settings.minY >= storage.maxY)
        #expect(settings.maxY <= size.height)
        #expect(size.height - settings.maxY <= 24, "Settings floats \(size.height - settings.maxY) pt above the bottom")
    }

    @Test(arguments: sizes)
    func clickingEachRowSelectsThatRow(size: CGSize) throws {
        let harness = try UIHarness()
        defer { harness.tearDown() }
        harness.model.onLaunch()
        let window = harness.host(ContentView(), size: size)

        // Bottom-up, so every click changes the selection (Smart Scan starts selected).
        for item in SidebarItem.allCases.reversed() {
            let row = try #require(harness.frame("sidebar.\(item.rawValue)"))
            harness.click(window, at: CGPoint(x: row.midX, y: row.midY))
            #expect(harness.navigation.selection == item, "clicking the drawn \(item) row selected something else")
        }
    }

    @Test func rowEdgesHitTheirOwnRow() throws {
        let harness = try UIHarness()
        defer { harness.tearDown() }
        harness.model.onLaunch()
        let window = harness.host(ContentView())

        // Just inside the top and bottom edges of each drawn row: an offset between drawing and hit areas of
        // more than a few points makes one of these land on a neighbour (or on nothing).
        for item in SidebarItem.modules.reversed() {
            let row = try #require(harness.frame("sidebar.\(item.rawValue)"))
            for y in [row.minY + 4, row.maxY - 4] {
                harness.navigation.selection = item == .smartScan ? .history : .smartScan
                harness.settle(0.05)
                harness.click(window, at: CGPoint(x: row.midX, y: y))
                #expect(harness.navigation.selection == item, "click at y=\(y) inside \(item) missed it")
            }
        }
    }

    @Test func headerIsNotClickable() throws {
        let harness = try UIHarness()
        defer { harness.tearDown() }
        harness.model.onLaunch()
        let window = harness.host(ContentView())
        harness.navigation.selection = .history
        harness.settle(0.05)

        let header = try #require(harness.frame("sidebar.header"))
        harness.click(window, at: CGPoint(x: header.midX, y: header.midY))
        #expect(harness.navigation.selection == .history)
    }
}
