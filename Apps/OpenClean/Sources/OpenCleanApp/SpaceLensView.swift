import OpenCleanAppModel
import QuickLook
import SwiftUI

/// Space Lens: a size map of any folder, large & old files, and duplicates. Everything it removes goes
/// to the macOS Trash, one ticked item at a time, after a confirmation sheet.
struct SpaceLensView: View {
    @Environment(SpaceLensModel.self) private var model
    @State private var preview = SpaceLensPreview()

    var body: some View {
        @Bindable var model = model
        @Bindable var preview = preview
        VStack(spacing: 0) {
            if model.phase(of: model.tab) != .scanning {
                Picker("Space Lens view", selection: $model.tab) {
                    ForEach(SpaceLensModel.Tab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 440)
                .padding(.top, 16)
            }
            Group {
                switch model.tab {
                case .map: SpaceMapTab()
                case .large: LargeFilesTab()
                case .duplicates: DuplicatesTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.3), value: model.phase(of: model.tab))
        .environment(preview)
        .quickLookPreview($preview.url)
        .sheet(isPresented: $model.isConfirmPresented) {
            SpaceLensConfirmSheet().environment(model)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { model.refreshAccess() }
    }
}
