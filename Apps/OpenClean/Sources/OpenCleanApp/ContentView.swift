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

    var isAvailable: Bool { true }
}

/// Which sidebar section is showing. Shared so the menu bar can switch sections.
@MainActor
@Observable
final class AppNavigation {
    var selection: SidebarItem? = .smartScan
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        @Bindable var model = model
        @Bindable var navigation = navigation
        NavigationSplitView {
            List(selection: $navigation.selection) {
                Section {
                    ForEach(SidebarItem.allCases.filter(\.isAvailable)) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                if SidebarItem.allCases.contains(where: { !$0.isAvailable }) {
                    Section("Coming soon") {
                        ForEach(SidebarItem.allCases.filter { !$0.isAvailable }) { item in
                            Label(item.title, systemImage: item.symbol)
                                .foregroundStyle(Theme.textTertiary)
                                .selectionDisabled()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sidebar.opacity(0.2))
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
            .frame(minWidth: 230)
            .navigationSplitViewColumnWidth(min: 230, ideal: 240, max: 280)
            // The sidebar is the app's only navigation, so it can't be hidden.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                AccessBanner()
                ProblemsBanner()
                Group {
                    switch navigation.selection ?? .smartScan {
                    case .smartScan: SmartScanView()
                    case .cleanup: CleanupView()
                    case .history: HistoryView()
                    case .uninstaller: UninstallerView()
                    case .spaceLens: SpaceLensView()
                    case .performance: PerformanceView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The hidden title bar still reserves a ~40 pt inset above the detail column; pull the content
            // up so the first element sits level with the window buttons instead of below an empty strip.
            .padding(.top, -28)
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
        switch navigation.selection ?? .smartScan {
        case .history: .history
        case .uninstaller: .uninstaller
        case .spaceLens: .spaceLens
        case .performance: .performance
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
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white)
            .accessibilityLabel("OpenClean")
    }
}
