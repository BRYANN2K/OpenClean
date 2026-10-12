import AppKit
import OpenCleanAppModel
import OpenCleanKit
import Permissions
import SwiftUI

@main
struct OpenCleanApp: App {
    @State private var model: AppModel
    @State private var uninstaller: UninstallerModel
    @State private var spaceLens: SpaceLensModel
    @State private var performance: PerformanceModel
    @State private var navigation = AppNavigation()
    @AppStorage(MenuBarSettings.enabledKey) private var menuBarEnabled = true

    init() {
        let coordinator = OpenCleanCoordinator()
        _model = State(
            initialValue: AppModel(
                coordinator: coordinator,
                signatureTracker: SignatureTracker(
                    defaults: .standard, currentSignature: SignatureTracker.currentCDHash())))
        _uninstaller = State(initialValue: UninstallerModel(coordinator: coordinator))
        _spaceLens = State(initialValue: SpaceLensModel(coordinator: coordinator))
        _performance = State(initialValue: PerformanceModel(coordinator: coordinator))
        // Needed when started with `swift run`; harmless inside OpenClean.app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("OpenClean", id: MenuBarSettings.mainWindowID) {
            ContentView()
                .environment(model)
                .environment(uninstaller)
                .environment(spaceLens)
                .environment(performance)
                .environment(navigation)
                .frame(minWidth: 1200, minHeight: 720)
                .task { model.onLaunch() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // No "Hide Sidebar" menu item: the sidebar is always shown.
            CommandGroup(replacing: .sidebar) {}
        }
        MenuBarExtra(isInserted: $menuBarEnabled) {
            MenuBarPopover()
                .environment(model)
                .environment(performance)
                .environment(navigation)
        } label: {
            MenuBarLabel().environment(performance)
        }
        .menuBarExtraStyle(.window)
        SwiftUI.Settings {
            SettingsView()
                .environment(model)
                .frame(width: 520)
        }
    }
}
