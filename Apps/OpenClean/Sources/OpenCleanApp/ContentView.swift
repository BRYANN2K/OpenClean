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
                            .foregroundStyle(Theme.textTertiary)
                            .selectionDisabled()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sidebar.opacity(0.55))
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 10) {
                    AppIconView(size: 28)
                    Wordmark(size: 17)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StorageCard(disk: model.disk, stats: model.stats).padding(12)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
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
            .foregroundStyle(.white)
            .background(backdrop.gradient.ignoresSafeArea())
            .animation(.easeInOut(duration: 0.35), value: model.phase)
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.isReviewPresented) { ReviewSheet() }
        .alert("Something went wrong", isPresented: $model.isErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var backdrop: Backdrop {
        switch selection ?? .smartScan {
        case .history: .history
        case .smartScan where model.phase == .finished: .success
        default: .scan
        }
    }
}

/// "OpenClean" set in the rounded system face: regular "Open", bold "Clean".
struct Wordmark: View {
    var size: CGFloat

    var body: some View {
        (Text("Open").fontWeight(.regular) + Text("Clean").fontWeight(.bold))
            .font(.system(size: size, design: .rounded))
            .kerning(-0.3)
            .foregroundStyle(.white)
            .accessibilityLabel("OpenClean")
    }
}
