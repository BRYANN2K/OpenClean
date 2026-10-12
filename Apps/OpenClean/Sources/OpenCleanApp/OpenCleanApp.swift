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
        WindowGroup("OpenClean") {
            ContentView()
                .environment(model)
                .environment(uninstaller)
                .environment(spaceLens)
                .environment(performance)
                .frame(minWidth: 1200, minHeight: 720)
                .task { model.onLaunch() }
        }
        .windowStyle(.hiddenTitleBar)
        SwiftUI.Settings {
            SettingsView()
                .environment(model)
                .frame(width: 520)
        }
    }
}
