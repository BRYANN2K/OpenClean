import Foundation
import Observation
import OpenCleanKit
import Permissions
import Quarantine
import RuleKit
import ScanEngine

/// All state behind the SwiftUI app. Views read it and call its actions; it never touches files itself.
@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable {
        case idle, scanning, results, cleaning, finished
    }

    public enum CheckState: Equatable {
        case on, off, mixed
    }

    public private(set) var phase: Phase = .idle
    public private(set) var progress: ScanProgress?
    public private(set) var result: ScanResult?
    public var selectedPaths: Set<String> = []
    public private(set) var lastReport: RemovalReport?
    public private(set) var loadedRules = LoadedRules()
    public private(set) var history: [SessionListing] = []
    public private(set) var accessAdvice: AccessAdvice = .ok
    public private(set) var settings: Settings
    public var errorMessage: String?
    public var isReviewPresented = false

    @ObservationIgnored private let coordinator: OpenCleanCoordinator
    @ObservationIgnored private let signatureTracker: SignatureTracker
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var settingsGeneration = 0

    public init(coordinator: OpenCleanCoordinator, signatureTracker: SignatureTracker) {
        self.coordinator = coordinator
        self.signatureTracker = signatureTracker
        settings = coordinator.settingsStore.load()
    }

    public var paths: AppPaths { coordinator.paths }

    public var isErrorPresented: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    // MARK: Lifecycle

    public func onLaunch() {
        coordinator.purgeExpired(settings: settings)
        reloadRules()
        refreshAccess()
        refreshHistory()
    }

    public func reloadRules() {
        loadedRules = coordinator.loadRules(includeCaution: settings.advancedEnabled)
    }

    public func refreshAccess() {
        accessAdvice = signatureTracker.advise(status: coordinator.fullDiskAccessStatus())
    }

    public func refreshHistory() {
        history = coordinator.history()
    }

    // MARK: Scanning

    public func startScan() {
        guard phase != .scanning, phase != .cleaning else { return }
        phase = .scanning
        progress = nil
        result = nil
        lastReport = nil
        let generation = settingsGeneration
        let rules = loadedRules.rules
        let settings = settings
        let coordinator = coordinator
        let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)
        scanTask = Task {
            async let scanned = coordinator.scan(rules, settings: settings, progress: continuation)
            for await update in stream {
                self.progress = update
            }
            let finished = await scanned
            if generation != self.settingsGeneration {
                self.result = nil
                self.selectedPaths = []
                self.progress = nil
                self.phase = .idle
                return
            }
            self.result = finished
            self.selectedPaths = DefaultSelection.paths(in: finished)
            self.phase = .results
        }
    }

    public func cancelScan() {
        scanTask?.cancel()
    }

    /// Waits for the current scan task (used by tests and the menu command).
    public func waitForScan() async {
        await scanTask?.value
    }

    // MARK: Cleaning

    public var plan: CleanupPlan? {
        result.map { CleanupPlan(result: $0, selectedPaths: selectedPaths) }
    }

    public func clean() async {
        guard phase == .results, let plan, !plan.isEmpty else { return }
        phase = .cleaning
        let generation = settingsGeneration
        let coordinator = coordinator
        do {
            let report = try await Task.detached { try coordinator.execute(plan) }.value
            lastReport = report
            if generation != settingsGeneration {
                result = nil
                selectedPaths = []
                phase = .idle
            } else {
                dropCleanedItems(report)
                phase = .finished
            }
        } catch {
            errorMessage = error.localizedDescription
            phase = .results
        }
        refreshHistory()
    }

    public func restore(sessionID: String, paths: Set<String>?, onConflict: ConflictPolicy) async -> RestoreReport? {
        guard phase != .scanning, phase != .cleaning else { return nil }
        let coordinator = coordinator
        do {
            let report = try await Task.detached {
                try coordinator.restore(sessionID: sessionID, paths: paths, onConflict: onConflict)
            }.value
            refreshHistory()
            return report
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func dropCleanedItems(_ report: RemovalReport) {
        let removed = Set(
            report.manifest.entries
                .filter { [.deleted, .quarantined, .trashed].contains($0.outcome) }
                .map(\.originalPath))
        guard var current = result else { return }
        for index in current.rules.indices {
            current.rules[index].items.removeAll { removed.contains($0.path) }
        }
        result = current
        selectedPaths.subtract(removed)
    }

    // MARK: Settings

    public func updateSettings(_ change: (inout Settings) -> Void) {
        let previous = settings
        change(&settings)
        settings.retentionDays = settings.clampedRetentionDays
        do {
            try coordinator.settingsStore.save(settings)
        } catch {
            errorMessage = "Could not save settings: \(error.localizedDescription)"
        }
        if previous.advancedEnabled != settings.advancedEnabled { reloadRules() }
        let invalidates = previous.advancedEnabled != settings.advancedEnabled
            || previous.excludedPaths != settings.excludedPaths
        if invalidates { settingsGeneration += 1 }
        if invalidates, result != nil, phase != .scanning, phase != .cleaning {
            result = nil
            selectedPaths = []
            lastReport = nil
            progress = nil
            phase = .idle
        }
    }

    public var retentionDays: Int {
        get { settings.retentionDays }
        set { updateSettings { $0.retentionDays = newValue } }
    }

    public var advancedEnabled: Bool {
        get { settings.advancedEnabled }
        set { updateSettings { $0.advancedEnabled = newValue } }
    }

    public func addExclusion(_ path: String) {
        updateSettings { settings in
            if !settings.excludedPaths.contains(path) { settings.excludedPaths.append(path) }
        }
    }

    public func removeExclusion(_ path: String) {
        updateSettings { $0.excludedPaths.removeAll { $0 == path } }
    }

    // MARK: Selection

    public func state(of rule: RuleResult) -> CheckState {
        state(for: removable(rule))
    }

    public func state(of category: RuleCategory) -> CheckState {
        state(for: itemsIn(category))
    }

    public func setSelected(_ selected: Bool, rule: RuleResult) {
        apply(selected, to: removable(rule))
    }

    public func setSelected(_ selected: Bool, category: RuleCategory) {
        apply(selected, to: itemsIn(category))
    }

    public func toggle(_ item: ScanItem) {
        guard !item.reportOnly else { return }
        if selectedPaths.contains(item.path) {
            selectedPaths.remove(item.path)
        } else {
            selectedPaths.insert(item.path)
        }
    }

    private func removable(_ rule: RuleResult) -> [ScanItem] {
        rule.items.filter { !$0.reportOnly }
    }

    private func itemsIn(_ category: RuleCategory) -> [ScanItem] {
        (result?.rules ?? []).filter { $0.rule.category == category }.flatMap { removable($0) }
    }

    private func state(for items: [ScanItem]) -> CheckState {
        guard !items.isEmpty else { return .off }
        let selected = items.filter { selectedPaths.contains($0.path) }.count
        if selected == 0 { return .off }
        return selected == items.count ? .on : .mixed
    }

    private func apply(_ selected: Bool, to items: [ScanItem]) {
        let paths = items.map(\.path)
        if selected {
            selectedPaths.formUnion(paths)
        } else {
            selectedPaths.subtract(paths)
        }
    }
}
