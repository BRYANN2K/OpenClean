import OpenCleanAppModel
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case smartScan, cleanup, history, uninstaller, spaceLens, performance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartScan: "Smart Scan"
        case .cleanup: "Cleanup"
        case .history: "History"
        case .uninstaller: "Uninstaller"
        case .spaceLens: "Space Lens"
        case .performance: "Performance"
        }
    }

    var symbol: String {
        switch self {
        case .smartScan: "sparkles"
        case .cleanup: "trash"
        case .history: "clock.arrow.circlepath"
        case .uninstaller: "xmark.app"
        case .spaceLens: "chart.pie"
        case .performance: "speedometer"
        }
    }

    var isAvailable: Bool { [.smartScan, .cleanup, .history].contains(self) }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .smartScan

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(SidebarItem.allCases.filter(\.isAvailable)) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("Coming soon") {
                    ForEach(SidebarItem.allCases.filter { !$0.isAvailable }) { item in
                        Label(item.title, systemImage: item.symbol)
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            VStack(spacing: 0) {
                AccessBanner()
                ProblemsBanner()
                Group {
                    switch selection ?? .smartScan {
                    case .smartScan: SmartScanView()
                    case .cleanup: CleanupView()
                    case .history: HistoryView()
                    default: ComingSoonView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $model.isReviewPresented) { ReviewSheet() }
        .alert("Something went wrong", isPresented: $model.isErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
