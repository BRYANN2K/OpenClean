import Foundation
import Observation
import OpenCleanKit
import Quarantine
import RuleKit
import SpaceKit

/// State behind the Space Lens module. Views read it and call its actions; it never touches files itself.
///
/// Nothing is ever selected for the user: every selection comes from a click on one item's checkbox.
/// Removals go to the macOS Trash through `OpenCleanCoordinator.moveToTrash`, which re-checks each item.
@MainActor
@Observable
public final class SpaceLensModel {
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case map, large, duplicates

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .map: "Space map"
            case .large: "Large & old files"
            case .duplicates: "Duplicates"
            }
        }
    }

    public enum Phase: Equatable, Sendable {
        case idle, scanning, results
    }

    /// One ticked item, as shown in the confirmation sheet and sent to the Trash.
    public struct TrashCandidate: Identifiable, Equatable, Sendable {
        public let name: String
        public let size: Int64
        public let isUserContent: Bool
        public let request: TrashRequest

        public var id: String { request.path }
        public var path: String { request.path }
        public var isDirectory: Bool { request.isDirectory }
    }

    public var tab: Tab = .map
    public var errorMessage: String?

    // Space map
    public private(set) var mapPhase: Phase = .idle
    public private(set) var mapRoot: String
    public private(set) var mapProgress = SpaceScanProgress()
    public private(set) var mapResult: SpaceScanResult?
    public private(set) var focusID: String?

    // Large & old files
    public private(set) var largePhase: Phase = .idle
    public private(set) var largeProgress = FinderProgress()
    public private(set) var largeResult: LargeFileResult?
    public var largeFilter = LargeFileFilter()
    public private(set) var includeUserContent = false

    // Duplicates
    public private(set) var duplicatePhase: Phase = .idle
    public private(set) var duplicateProgress = FinderProgress()
    public private(set) var duplicateResult: DuplicateResult?
    public private(set) var duplicateRoots: [String]

    // Trash
    public private(set) var selections: [Tab: [String: TrashCandidate]] = [:]
    public var isConfirmPresented = false
    public private(set) var isTrashing = false
    public private(set) var lastReport: TrashReport?
    public private(set) var hasFullDiskAccess = true

    @ObservationIgnored let coordinator: OpenCleanCoordinator
    @ObservationIgnored private let policy: TrashPolicy
    @ObservationIgnored private var tasks: [Tab: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [Tab: Int] = [:]

    public init(coordinator: OpenCleanCoordinator) {
        self.coordinator = coordinator
        policy = coordinator.trashPolicy
        mapRoot = coordinator.spaceLensHome
        duplicateRoots = coordinator.defaultDuplicateRoots
    }

    public var home: String { coordinator.spaceLensHome }

    public func refreshAccess() {
        hasFullDiskAccess = coordinator.fullDiskAccessStatus() == .granted
    }

    public func phase(of tab: Tab) -> Phase {
        switch tab {
        case .map: mapPhase
        case .large: largePhase
        case .duplicates: duplicatePhase
        }
    }

    // MARK: Scanning

    public func startMapScan(root: String? = nil) {
        if let root { mapRoot = realPath(root) ?? root }
        let generation = begin(.map)
        mapPhase = .scanning
        mapProgress = SpaceScanProgress()
        mapResult = nil
        focusID = nil
        let coordinator = coordinator
        let root = mapRoot
        let (stream, continuation) = AsyncStream.makeStream(
            of: SpaceScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        tasks[.map] = Task {
            async let scanned: SpaceScanResult? = {
                defer { continuation.finish() }
                return await coordinator.scanSpace(root: root, progress: continuation)
            }()
            for await update in stream { self.mapProgress = update }
            let result = await scanned
            guard self.generations[.map] == generation else { return }
            guard let result else {
                self.mapPhase = .idle
                self.errorMessage = "That folder can't be scanned. It may have been moved or deleted."
                return
            }
            self.mapResult = result
            self.mapPhase = .results
        }
    }

    public func startLargeScan() {
        let generation = begin(.large)
        largePhase = .scanning
        largeProgress = FinderProgress()
        largeResult = nil
        let coordinator = coordinator
        let options = LargeFileOptions(includeUserContent: includeUserContent)
        let (stream, continuation) = AsyncStream.makeStream(
            of: FinderProgress.self, bufferingPolicy: .bufferingNewest(1))
        tasks[.large] = Task {
            async let found: LargeFileResult = {
                defer { continuation.finish() }
                return await coordinator.findLargeFiles(options: options, progress: continuation)
            }()
            for await update in stream { self.largeProgress = update }
            let result = await found
            guard self.generations[.large] == generation else { return }
            self.largeResult = result
            self.largePhase = .results
        }
    }

    public func startDuplicateScan() {
        guard !duplicateRoots.isEmpty else { return }
        let generation = begin(.duplicates)
        duplicatePhase = .scanning
        duplicateProgress = FinderProgress()
        duplicateResult = nil
        let coordinator = coordinator
        let roots = duplicateRoots
        let (stream, continuation) = AsyncStream.makeStream(
            of: FinderProgress.self, bufferingPolicy: .bufferingNewest(1))
        tasks[.duplicates] = Task {
            async let found: DuplicateResult = {
                defer { continuation.finish() }
                return await coordinator.findDuplicates(roots: roots, progress: continuation)
            }()
            for await update in stream { self.duplicateProgress = update }
            let result = await found
            guard self.generations[.duplicates] == generation else { return }
            self.duplicateResult = result
            self.duplicatePhase = .results
        }
    }

    public func startScan(_ tab: Tab) {
        switch tab {
        case .map: startMapScan()
        case .large: startLargeScan()
        case .duplicates: startDuplicateScan()
        }
    }

    /// Stops a running scan; whatever was found so far is shown, marked incomplete.
    public func stopScan(_ tab: Tab) {
        tasks[tab]?.cancel()
    }

    /// Discards a tab's results and selection and returns to its start screen. Never touches files.
    public func startOver(_ tab: Tab) {
        _ = begin(tab)
        switch tab {
        case .map:
            mapPhase = .idle
            mapResult = nil
            focusID = nil
        case .large:
            largePhase = .idle
            largeResult = nil
        case .duplicates:
            duplicatePhase = .idle
            duplicateResult = nil
        }
    }

    /// Waits for a tab's scan task (used by tests).
    public func waitForScan(_ tab: Tab) async {
        await tasks[tab]?.value
    }

    /// Cancels any previous scan of `tab`, clears its selection, and returns the new generation.
    private func begin(_ tab: Tab) -> Int {
        tasks[tab]?.cancel()
        tasks[tab] = nil
        selections[tab] = [:]
        lastReport = nil
        let next = (generations[tab] ?? 0) + 1
        generations[tab] = next
        return next
    }

    // MARK: Options

    public func setIncludeUserContent(_ include: Bool) {
        guard include != includeUserContent else { return }
        includeUserContent = include
        if largePhase == .results { startLargeScan() }
    }

    public func addDuplicateRoot(_ path: String) {
        let canonical = realPath(path) ?? path
        guard !duplicateRoots.contains(canonical) else { return }
        duplicateRoots.append(canonical)
    }

    public func removeDuplicateRoot(_ path: String) {
        duplicateRoots.removeAll { $0 == path }
    }

    public func resetDuplicateRoots() {
        duplicateRoots = coordinator.defaultDuplicateRoots
    }

    // MARK: Space map navigation

    public var focusedNode: SpaceNode? {
        guard let root = mapResult?.root else { return nil }
        guard let focusID else { return root }
        return root.node(withID: focusID) ?? root
    }

    /// From the scan root down to the focused folder.
    public var breadcrumb: [SpaceNode] {
        guard let root = mapResult?.root else { return [] }
        guard let focusID else { return [root] }
        return root.trail(to: focusID) ?? [root]
    }

    public func focus(on id: String) {
        guard let node = mapResult?.root.node(withID: id), node.isDirectory else { return }
        focusID = id == mapResult?.root.id ? nil : id
    }

    public func goUp() {
        let trail = breadcrumb
        guard trail.count > 1 else { return }
        focus(on: trail[trail.count - 2].id)
    }

    // MARK: Selection

    public var selection: [String: TrashCandidate] { selections[tab] ?? [:] }

    public var selectedCandidates: [TrashCandidate] {
        selection.values.sorted { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
    }

    public var selectedBytes: Int64 { selection.values.reduce(0) { $0 + $1.size } }

    public func isSelected(_ path: String) -> Bool { selection[path] != nil }

    /// Why an item can't be moved to the Trash, or nil when it can.
    public func protection(for path: String, isDirectory: Bool) -> String? {
        policy.verdict(for: path, isDirectory: isDirectory).refusal
    }

    public func candidate(for node: SpaceNode) -> TrashCandidate? {
        guard let snapshot = node.snapshot, let result = mapResult, node.id != result.root.id else { return nil }
        return makeCandidate(snapshot, name: node.name, size: node.size, root: result.rootPath)
    }

    public func candidate(for file: LargeFile) -> TrashCandidate {
        makeCandidate(file.snapshot, name: file.name, size: file.size, root: file.scanRoot)
    }

    public func candidate(for file: DuplicateFile) -> TrashCandidate {
        makeCandidate(file.snapshot, name: file.name, size: file.size, root: file.scanRoot)
    }

    private func makeCandidate(_ snapshot: FileSnapshot, name: String, size: Int64, root: String) -> TrashCandidate {
        TrashCandidate(
            name: name, size: size, isUserContent: policy.isUserContent(snapshot.path),
            request: TrashRequest(
                path: snapshot.path, scanRoot: root, device: snapshot.device, inode: snapshot.inode,
                modificationDate: snapshot.modificationDate, isDirectory: snapshot.isDirectory, bytes: size))
    }

    /// Ticks or unticks one item in the current tab. Protected items can't be ticked.
    public func toggle(_ candidate: TrashCandidate) {
        var current = selections[tab] ?? [:]
        if current[candidate.path] != nil {
            current[candidate.path] = nil
        } else {
            guard protection(for: candidate.path, isDirectory: candidate.isDirectory) == nil else { return }
            current[candidate.path] = candidate
        }
        selections[tab] = current
    }

    /// A duplicate copy can be ticked unless it is the last unticked copy of its group.
    public func canSelect(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool {
        let chosen = selections[.duplicates] ?? [:]
        if chosen[file.path] != nil { return true }
        guard protection(for: file.path, isDirectory: false) == nil else { return false }
        return group.files.filter { chosen[$0.path] == nil }.count > 1
    }

    public func toggle(_ file: DuplicateFile, in group: DuplicateGroup) {
        guard tab == .duplicates, canSelect(file, in: group) else { return }
        toggle(candidate(for: file))
    }

    // MARK: Large & old

    public var visibleLargeFiles: [LargeFile] {
        largeFilter.apply(largeResult?.files ?? [])
    }

    public var largeGroups: [(kind: FileKind, files: [LargeFile])] {
        LargeFileFilter.grouped(visibleLargeFiles)
    }

    // MARK: Trash

    public func requestTrash() {
        guard !selection.isEmpty, !isTrashing else { return }
        isConfirmPresented = true
    }

    public func confirmTrash() async {
        let candidates = selectedCandidates
        guard !candidates.isEmpty, !isTrashing else { return }
        isTrashing = true
        let coordinator = coordinator
        let requests = candidates.map(\.request)
        let report = await Task.detached { coordinator.moveToTrash(requests) }.value
        apply(report)
        isTrashing = false
        isConfirmPresented = false
        lastReport = report
    }

    public func dismissReport() {
        lastReport = nil
    }

    /// Removes trashed items (and anything inside trashed folders) from every tab's results and selection.
    private func apply(_ report: TrashReport) {
        let trashed = report.trashed.map(\.path)
        guard !trashed.isEmpty else { return }
        func gone(_ path: String) -> Bool {
            trashed.contains { pathIsWithin(path, $0, caseInsensitive: true) }
        }
        if var result = mapResult {
            result.root = result.root.removing(Set(trashed))
            mapResult = result
            if let focusID, result.root.node(withID: focusID) == nil { self.focusID = nil }
        }
        if var result = largeResult {
            result.files.removeAll { gone($0.path) }
            largeResult = result
        }
        if var result = duplicateResult {
            result.groups = result.groups.compactMap { group in
                group.removing(Set(group.files.map(\.path).filter(gone)))
            }
            duplicateResult = result
        }
        for key in Tab.allCases {
            selections[key] = selections[key]?.filter { !gone($0.key) }
        }
    }
}
