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
    @State private var onboarding = OnboardingModel(defaults: .standard)
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
            Group {
                if onboarding.isCompleted {
                    ContentView()
                } else {
                    OnboardingView()
                }
            }
            .animation(.easeInOut(duration: 0.5), value: onboarding.isCompleted)
            .environment(model)
            .environment(uninstaller)
            .environment(spaceLens)
            .environment(performance)
            .environment(navigation)
            .environment(onboarding)
            .frame(minWidth: 1200, minHeight: 720)
            .task { model.onLaunch() }
        }
        .windowStyle(.hiddenTitleBar)
        // Open at a comfortable size and never let the window shrink below the layout's minimum.
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            // No "Hide Sidebar" menu item: the sidebar is always shown.
            CommandGroup(replacing: .sidebar) {}
            CommandGroup(before: .help) {
                Button("Welcome Tour…") { onboarding.restart() }
                    .disabled(!onboarding.isCompleted)
            }
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
