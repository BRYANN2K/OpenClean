import AppKit
import OpenCleanAppModel
import OpenCleanKit
import Permissions
import SwiftUI

@main
struct OpenCleanApp: App {
    @State private var model = AppModel(
        coordinator: OpenCleanCoordinator(),
        signatureTracker: SignatureTracker(defaults: .standard, currentSignature: SignatureTracker.currentCDHash()))

    init() {
        // Needed when started with `swift run`; harmless inside OpenClean.app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("OpenClean") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
                .task { model.onLaunch() }
        }
        SwiftUI.Settings {
            SettingsView()
                .environment(model)
                .frame(width: 520)
        }
    }
}
