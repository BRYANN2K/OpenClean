import AppInventory
import Foundation
import Observation
import OpenCleanKit
import Quarantine

/// State behind the Uninstaller module. Views read it and call its actions; it never touches files itself.
@MainActor
@Observable
public final class UninstallerModel {
    public enum Phase: Equatable {
        /// Nothing loaded (first launch, or loading was stopped).
        case idle
        case loading
        case list
        case uninstalling
        case finished
    }

    public private(set) var phase: Phase = .idle
    public private(set) var progress: AppInventoryProgress?
    public private(set) var apps: [InstalledApp] = []
    public var searchText = ""
    public private(set) var selectedAppID: String?
    public private(set) var leftovers: [Leftover] = []
    public private(set) var isFindingLeftovers = false
    /// Whether the selected app is running right now (checked when it is selected).
    public private(set) var selectedAppIsRunning = false
    public private(set) var selectedLeftovers: Set<String> = []
    /// The app the last uninstall was for, and what happened.
    public private(set) var processedApp: InstalledApp?
    public private(set) var outcome: UninstallOutcome?
    public var isConfirmPresented = false
    public var errorMessage: String?

    @ObservationIgnored let coordinator: OpenCleanCoordinator
    @ObservationIgnored private let lastUsed: (any LastUsedProvider)?
    @ObservationIgnored private let systemLibrary: String
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var leftoverTask: Task<Void, Never>?
    @ObservationIgnored private var selectionGeneration = 0
    @ObservationIgnored private var didAutoLoad = false

    public init(
        coordinator: OpenCleanCoordinator, lastUsed: (any LastUsedProvider)? = MdlsLastUsedProvider(),
        systemLibrary: String = "/Library"
    ) {
        self.coordinator = coordinator
        self.lastUsed = lastUsed
        self.systemLibrary = systemLibrary
    }

    // MARK: Loading

    /// Loads the app list the first time the screen appears.
    public func onAppear() {
        guard !didAutoLoad, phase == .idle else { return }
        didAutoLoad = true
        load()
    }

    public func load() {
        guard phase != .loading, phase != .uninstalling else { return }
        phase = .loading
        progress = nil
        let coordinator = coordinator
        let lastUsed = lastUsed
        let (stream, continuation) = AsyncStream.makeStream(of: AppInventoryProgress.self)
        loadTask = Task {
            async let listed = coordinator.installedApps(lastUsed: lastUsed, progress: continuation)
            for await update in stream {
                self.progress = update
            }
            let result = await listed
            if Task.isCancelled {
                self.apps = []
                self.clearSelection()
                self.phase = .idle
                return
            }
            self.apps = result
            self.phase = .list
            if let selected = self.selectedApp {
                self.select(selected)
            } else {
                self.clearSelection()
            }
        }
    }

    public func stopLoading() {
        loadTask?.cancel()
    }

    /// Waits for the current load (used by tests).
    public func waitForLoad() async {
        await loadTask?.value
    }

    // MARK: Selection

    /// Apps OpenClean can uninstall, including root-owned ones (they ask for an administrator password).
    /// Apple apps, Utilities, apps without a bundle id and OpenClean itself are left out of the list.
    public var uninstallableApps: [InstalledApp] {
        apps.filter { $0.status.isRemovable || $0.status == .needsAdministrator }
    }

    public var filteredApps: [InstalledApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return uninstallableApps }
        return uninstallableApps.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.bundleID?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    public var selectedApp: InstalledApp? {
        selectedAppID.flatMap { id in apps.first { $0.id == id } }
    }

    public var totalAppBytes: Int64 { uninstallableApps.reduce(0) { $0 + $1.size } }

    public var removableLeftovers: [Leftover] { leftovers.filter { !$0.isReportOnly } }
    public var reportOnlyLeftovers: [Leftover] { leftovers.filter(\.isReportOnly) }

    /// Removable leftovers grouped by kind, in `LeftoverKind.allCases` order.
    public var leftoverGroups: [(kind: LeftoverKind, items: [Leftover])] {
        let removable = removableLeftovers
        return LeftoverKind.allCases.compactMap { kind in
            let items = removable.filter { $0.kind == kind }
            return items.isEmpty ? nil : (kind, items)
        }
    }

    public var chosenLeftovers: [Leftover] { removableLeftovers.filter { selectedLeftovers.contains($0.id) } }

    /// The app plus the ticked leftovers.
    public var selectedBytes: Int64 {
        guard let app = selectedApp, app.status.isRemovable else { return 0 }
        return app.size + chosenLeftovers.reduce(0) { $0 + $1.size }
    }

    public func select(_ app: InstalledApp) {
        let changed = selectedAppID != app.id
        selectedAppID = app.id
        if changed {
            leftovers = []
            selectedLeftovers = []
        }
        selectedAppIsRunning = app.isRunning
        guard app.bundleID != nil else {
            isFindingLeftovers = false
            return
        }
        isFindingLeftovers = true
        selectionGeneration += 1
        let generation = selectionGeneration
        let coordinator = coordinator
        let systemLibrary = systemLibrary
        let others = Set(apps.compactMap(\.bundleID)).subtracting([app.bundleID ?? ""])
        leftoverTask = Task {
            let (found, running) = await Task.detached {
                (
                    coordinator.leftovers(for: app, otherBundleIDs: others, systemLibrary: systemLibrary),
                    app.bundleID.map { coordinator.isAppRunning(bundleID: $0) } ?? false
                )
            }.value
            guard generation == self.selectionGeneration, self.selectedAppID == app.id else { return }
            let previous = Set(self.leftovers.map(\.id))
            self.leftovers = found
            // Keep the user's choices across a re-check; tick new bundle-id matches by default.
            self.selectedLeftovers =
                self.selectedLeftovers.intersection(found.map(\.id))
                .union(found.filter { $0.isSelectedByDefault && !previous.contains($0.id) }.map(\.id))
            self.selectedAppIsRunning = running
            self.isFindingLeftovers = false
        }
    }

    /// Waits until the leftover search for the current selection has finished (used by tests).
    public func waitForLeftovers() async {
        await leftoverTask?.value
    }

    public func isSelected(_ leftover: Leftover) -> Bool { selectedLeftovers.contains(leftover.id) }

    public func toggle(_ leftover: Leftover) {
        guard !leftover.isReportOnly, leftovers.contains(leftover) else { return }
        if selectedLeftovers.contains(leftover.id) {
            selectedLeftovers.remove(leftover.id)
        } else {
            selectedLeftovers.insert(leftover.id)
        }
    }

    private func clearSelection() {
        selectedAppID = nil
        leftovers = []
        selectedLeftovers = []
        selectedAppIsRunning = false
        isFindingLeftovers = false
    }

    // MARK: Uninstalling

    public var canUninstall: Bool {
        guard phase == .list, let app = selectedApp else { return false }
        return app.status.isRemovable && !selectedAppIsRunning && !isFindingLeftovers
    }

    public func requestUninstall() {
        guard canUninstall else { return }
        isConfirmPresented = true
    }

    public func uninstall() async {
        guard canUninstall, let app = selectedApp else { return }
        isConfirmPresented = false
        phase = .uninstalling
        processedApp = app
        outcome = nil
        errorMessage = nil
        let chosen = chosenLeftovers
        let coordinator = coordinator
        do {
            outcome = try await Task.detached { try coordinator.uninstall(app, leftovers: chosen) }.value
        } catch {
            errorMessage = error.localizedDescription
        }
        phase = .finished
    }

    /// True when the app bundle itself ended up in quarantine (or the Trash).
    public var appWasRemoved: Bool {
        guard case .finished(let report) = outcome, let entry = report.manifest.entries.first else { return false }
        return entry.outcome == .quarantined || entry.outcome == .trashed
    }

    /// Leaves the summary and reloads the list, since sizes and the app set have changed.
    public func done() {
        guard phase == .finished else { return }
        if appWasRemoved { clearSelection() }
        outcome = nil
        processedApp = nil
        errorMessage = nil
        phase = .list
        load()
    }
}
