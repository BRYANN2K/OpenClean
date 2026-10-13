import AppKit
import Foundation
import OpenCleanAppModel
import OpenCleanKit
import Permissions
import ScanEngine
import SwiftUI
import TestSupport
import Updater

@testable import OpenCleanApp

/// Builds the app's models over a temporary home with fakes from TestSupport, and hosts SwiftUI views in an
/// `NSWindow` set up like the app's (`.hiddenTitleBar`: full-size content view, transparent title bar).
/// Fast and in-process, but not the SwiftUI scene's own window: AppKit builds the split view differently there
/// (on macOS 27, a glass sidebar here vs. a visual-effect sidebar in the app), so bugs that depend on the
/// scene window are covered by `AppWindowLayoutTests`, which runs the real app.
@MainActor
final class UIHarness {
    let home: TempDirectory
    let coordinator: OpenCleanCoordinator
    let model: AppModel
    let uninstaller: UninstallerModel
    let spaceLens: SpaceLensModel
    let performance: PerformanceModel
    let updates: UpdateModel
    let onboarding: OnboardingModel
    let reminder: ScanReminderModel
    let reminderSettings: ScanReminderSettingsStore
    let navigation = AppNavigation()
    let probe = LayoutProbe()
    private var windows: [NSWindow] = []
    private let suites: [String]

    /// - Parameter rulesDirectory: rule packs to load instead of `FixtureRules` (the screenshot recorder
    ///   uses the bundled `Rules/`).
    /// - Parameter probes: probes for those rules (packs naming an unknown probe are skipped whole).
    init(
        reminderFinding: ScanReminderFinding? = nil, rulesDirectory: String? = nil, probes: [any Probe] = []
    ) throws {
        _ = NSApplication.shared
        home = try TempDirectory()
        let rules = try rulesDirectory ?? FixtureRules.writeDirectory(in: home)
        // OPENCLEAN_HOME makes the coordinator treat the temp folder as a pretend home everywhere (quarantine,
        // settings, Updates, the Uninstaller's app folders), so nothing reads or writes the real home.
        coordinator = OpenCleanCoordinator(
            home: home.path, environment: ["OPENCLEAN_HOME": home.path, "OPENCLEAN_RULES_DIR": rules],
            registry: ProbeRegistry(probes), processChecker: FakeProcessChecker(), openFiles: FakeOpenFiles(),
            admin: FakeAdminExecutor(), fullDiskAccess: { .granted }, trash: { _ in nil })
        let modelSuite = "openclean.ui-tests.\(UUID().uuidString)"
        let updateSuite = "openclean.ui-tests.\(UUID().uuidString)"
        let onboardingSuite = "openclean.ui-tests.\(UUID().uuidString)"
        let reminderSuite = "openclean.ui-tests.\(UUID().uuidString)"
        suites = [modelSuite, updateSuite, onboardingSuite, reminderSuite]
        model = AppModel(
            coordinator: coordinator,
            signatureTracker: SignatureTracker(
                defaults: UserDefaults(suiteName: modelSuite)!, currentSignature: "test"),
            diskSpace: { _ in DiskSpace(available: 186_000_000_000, total: 494_000_000_000) })
        uninstaller = UninstallerModel(
            coordinator: coordinator, lastUsed: nil, systemLibrary: home.path + "/SystemLibrary")
        spaceLens = SpaceLensModel(coordinator: coordinator)
        performance = PerformanceModel(coordinator: coordinator, availableTasks: [])
        let updateSettings = UpdateSettingsStore(defaults: UserDefaults(suiteName: updateSuite)!)
        updateSettings.autoCheck = false
        updates = UpdateModel(
            coordinator: coordinator, settings: updateSettings, client: FakeHTTPClient(),
            installer: NoUpdateInstaller(), currentVersion: "0.2.0", currentAppPath: "/Applications/OpenClean.app",
            relaunch: { _ in }, cleanUpUpdates: {})
        onboarding = OnboardingModel(defaults: UserDefaults(suiteName: onboardingSuite)!)
        // Never started, so it never scans in the background; tests set its stored state directly.
        reminderSettings = ScanReminderSettingsStore(defaults: UserDefaults(suiteName: reminderSuite)!)
        reminderSettings.lastFinding = reminderFinding
        reminder = ScanReminderModel(
            settings: reminderSettings,
            scan: { ScanReminderFinding(date: Date(), bytes: 0, itemCount: 0) }, notifier: SilentReminderNotifier())
    }

    /// The repo's bundled rule packs (`Rules/`).
    nonisolated static var bundledRules: String {
        // Apps/OpenClean/Tests/OpenCleanAppUITests/<file> → the repo root.
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Rules").path
    }

    func tearDown() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        windows = []
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    /// `view` with every model the app's scenes put in the environment.
    func withEnvironment<V: View>(_ view: V) -> some View {
        view
            .environment(model)
            .environment(uninstaller)
            .environment(spaceLens)
            .environment(performance)
            .environment(navigation)
            .environment(onboarding)
            .environment(updates)
            .environment(reminder)
            .environment(\.layoutProbe, probe)
    }

    /// True when a window server is reachable (a logged-in GUI session). GitHub's macOS runners have one;
    /// a bare SSH session may not, and creating a window there would abort the whole test process.
    nonisolated static var hasWindowServer: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["kCGSSessionOnConsoleKey"] as? Bool ?? true
    }

    /// Hosts `view` in a window shaped like the app's main window and lets SwiftUI lay it out.
    @discardableResult
    func host<V: View>(_ view: V, size: CGSize = CGSize(width: 1200, height: 760)) -> NSWindow {
        let hosting = NSHostingView(rootView: AnyView(withEnvironment(view)))
        let window = UnconstrainedWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        // On screen, so AppKit applies the title-bar safe-area insets, but invisible, so a developer running
        // the tests sees nothing and real clicks pass through.
        window.alphaValue = 0
        window.orderFront(nil)
        windows.append(window)
        settle()
        return window
    }

    /// Runs the main run loop briefly so SwiftUI commits pending updates and layout.
    func settle(_ seconds: TimeInterval = 0.3) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            for window in windows { window.layoutIfNeeded() }
        }
    }

    /// The frame `id` was laid out at, in window coordinates with a top-left origin.
    func frame(_ id: String) -> CGRect? { probe.frames[id] }

    /// Sends a left click to `window` at `point` (top-left origin, like the probe's frames) through the normal
    /// event path, so it lands on whatever SwiftUI hit-tests at that point.
    func click(_ window: NSWindow, at point: CGPoint) {
        // The content view fills the window (full-size content view), so only the y axis flips.
        let location = NSPoint(x: point.x, y: window.frame.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)
            else { continue }
            window.sendEvent(event)
        }
        settle(0.1)
    }
}

/// Never stages or installs anything.
struct NoUpdateInstaller: UpdateInstalling {
    struct Unsupported: Error {}
    func stage(_ download: VerifiedDownload) throws -> StagedUpdate { throw Unsupported() }
    func installBlocker(currentApp: String) -> String? { "Tests never install updates." }
    func install(_ staged: StagedUpdate, currentApp: String) throws { throw Unsupported() }
}

/// Never shows a notification; reports notifications as turned off so Settings shows that row too.
struct SilentReminderNotifier: ScanReminderNotifying {
    func requestAuthorization() async -> Bool { false }
    func isAuthorized() async -> Bool { false }
    func post(title: String, body: String) async {}
}

/// Probes for every id the bundled packs name, all finding nothing: the real ones would ask the real Mac
/// (simctl, brew, tmutil, Docker), and a pack naming an unknown probe is skipped whole.
enum EmptyProbes {
    static let all: [any Probe] = [
        DevProjectBuildOutputs(), DockerDiskImage(), HomebrewCache(), NodeProjectModules(), PythonProjectVenvs(),
        RustProjectTargets(), TimemachineLocalSnapshots(), XcodeSimulators(),
    ]

    struct DevProjectBuildOutputs: Probe {
        static let id = "dev.project-build-outputs"
        func scan(_ context: ScanContext) async throws -> [ProbeFinding] { [] }
    }
    struct DockerDiskImage: Probe {
        static let id = "docker.disk-image"
        func scan(_ context: ScanContext) async throws -> [ProbeFinding] { [] }
    }
    struct HomebrewCache: Probe {
        static let id = "homebrew.cache"
        func scan(_ context: ScanContext) async throws -> [ProbeFinding] { [] }
    }
    struct NodeProjectModules: Probe {
        static let id = "node.project-modules"
        func scan(_ context: ScanContext) async throws -> [ProbeFinding] { [] }
    }
    struct PythonProjectVenvs: Probe {
        static let id = "python.project-venvs"
        func scan(_ context: ScanContext) async throws -> [ProbeFinding] { [] }
    }
    struct RustProjectTargets: Probe {
        static let id = "rust.project-targets"
        func scan(_ context: ScanContext) async throws -> [ProbeFinding] { [] }
    }
    struct TimemachineLocalSnapshots: Probe {
        static let id = "timemachine.local-snapshots"
        func scan(_ context: ScanContext) async throws -> [ProbeFinding] { [] }
    }
    struct XcodeSimulators: Probe {
        static let id = "xcode.simulators"
        func scan(_ context: ScanContext) async throws -> [ProbeFinding] { [] }
    }
}

/// A window AppKit doesn't shrink to fit the screen: CI runners have a 1024 × 768 display, smaller than the
/// app's 1200 × 720 minimum, and the tests must lay views out at the sizes they ask for.
final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
