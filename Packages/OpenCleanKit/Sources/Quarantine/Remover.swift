import Foundation
import Privilege
import RuleKit
import ScanEngine

public struct RemovalRequest: Sendable {
    public let item: ScanItem
    public let rule: Rule

    public init(item: ScanItem, rule: Rule) {
        self.item = item
        self.rule = rule
    }
}

public struct RemovalReport: Sendable {
    public let manifest: SessionManifest

    public init(manifest: SessionManifest) {
        self.manifest = manifest
    }

    public var deletedBytes: Int64 { manifest.deletedBytes }
    public var quarantinedBytes: Int64 { manifest.quarantinedBytes }
    public var skipped: [ManifestEntry] { manifest.skippedEntries }
    public var hadSkips: Bool { !skipped.isEmpty }
}

/// How request 0 of an uninstall (an app bundle the user can't move: root-owned or not writable) is moved
/// into quarantine: one `AppBundleAdminMove` behind an administrator password prompt.
public struct AdminBundleMove: Sendable {
    public let executor: any AppBundleAdminExecutor
    public let bundleID: String
    public let applicationFolders: [String]
    public let protectedPaths: [String]

    public init(
        executor: any AppBundleAdminExecutor, bundleID: String, applicationFolders: [String],
        protectedPaths: [String]
    ) {
        self.executor = executor
        self.bundleID = bundleID
        self.applicationFolders = applicationFolders
        self.protectedPaths = protectedPaths
    }
}

/// Moves `path` to the Trash and returns where it ended up.
public typealias TrashOperation = @Sendable (String) throws -> String?

/// The only component that removes files. Every item passes `PreDeleteChecker` first;
/// every outcome is written to the session manifest.
public struct Remover: Sendable {
    static let checkpointInterval = 50

    let store: QuarantineStore
    let checker: PreDeleteChecker
    let admin: any AdminExecutor
    let deviceOf: @Sendable (String) -> Int32?
    let trash: TrashOperation
    let parentIsProtected: @Sendable (String) -> Bool

    public static let systemTrash: TrashOperation = { path in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        return resulting?.path
    }

    /// True when no non-root user could swap an ancestor of `path` for a symlink before the root `rm`.
    /// Walks from the parent up to (excluding) "/". Each ancestor must be a real directory and either
    /// root-owned and not writable by the current user, or root-owned sticky (S_ISVTX; a sticky dir's owner can rename entries) with the next path component
    /// below it (the item itself for the direct parent) root-owned and not a symlink.
    public static let systemParentIsProtected: @Sendable (String) -> Bool = { path in
        let bytes = Array(path.utf8)
        let separators = bytes.indices.filter { $0 > 0 && bytes[$0] == 0x2F }
        for (position, index) in separators.enumerated() {
            let ancestor = String(decoding: bytes[..<index], as: UTF8.self)
            let nextEnd = position + 1 < separators.count ? separators[position + 1] : bytes.count
            let next = String(decoding: bytes[..<nextEnd], as: UTF8.self)
            if !ancestorIsProtected(ancestor, next: next) { return false }
        }
        return true
    }

    /// One step of `systemParentIsProtected`: `next` is the path component directly below `ancestor`.
    static func ancestorIsProtected(_ ancestor: String, next: String) -> Bool {
        guard let stat = FileStat.of(ancestor), !stat.isSymlink, stat.isDirectory else { return false }
        if stat.ownerUID == 0 && access(ancestor, W_OK) != 0 { return true }
        var info = Darwin.stat()
        let sticky = lstat(ancestor, &info) == 0 && (info.st_mode & S_ISVTX) != 0
        guard sticky, stat.ownerUID == 0, let child = FileStat.of(next) else { return false }
        return child.ownerUID == 0 && !child.isSymlink
    }

    public init(
        store: QuarantineStore, checker: PreDeleteChecker, admin: any AdminExecutor,
        deviceOf: @escaping @Sendable (String) -> Int32? = { FileStat.of($0)?.device },
        trash: @escaping TrashOperation = Remover.systemTrash,
        parentIsProtected: @escaping @Sendable (String) -> Bool = Remover.systemParentIsProtected
    ) {
        self.store = store
        self.checker = checker
        self.admin = admin
        self.deviceOf = deviceOf
        self.trash = trash
        self.parentIsProtected = parentIsProtected
    }

    /// With `adminBundle`, request 0 is moved with `AppBundleAdminMove` (after the usual pre-delete check)
    /// and the other requests are only processed if it ended up in quarantine; otherwise they are skipped.
    public func remove(
        _ requests: [RemovalRequest], now: Date = .now, adminBundle: AdminBundleMove? = nil
    ) throws -> RemovalReport {
        var manifest = try store.createSession(now: now)
        let itemsDirectory = store.itemsDirectory(manifest.id)
        let quarantineDevice = deviceOf(itemsDirectory.path)

        // Record intent first: a crash after a move still leaves a restorable entry.
        manifest.entries = requests.enumerated().map { index, request in
            let mode = request.rule.effectiveDeleteMode
            let planned =
                mode == .quarantine && !request.rule.needs(.admin)
                ? itemsDirectory.appendingPathComponent("\(index)")
                    .appendingPathComponent((request.item.path as NSString).lastPathComponent).path
                : nil
            return ManifestEntry(
                id: index, originalPath: request.item.path, storedPath: planned, size: request.item.size,
                ruleID: request.rule.id, mode: mode, outcome: .pending, reason: nil)
        }
        try store.write(manifest)

        var firstIndex = 0
        if let adminBundle, let bundle = requests.first {
            if let reason = checker.check(bundle.item, rule: bundle.rule) {
                mark(&manifest, 0, .skipped, reason.description)
            } else {
                moveBundleAsAdmin(
                    bundle, &manifest, adminBundle, itemsDirectory: itemsDirectory.path,
                    quarantineDevice: quarantineDevice)
            }
            try store.write(manifest)
            firstIndex = 1
            guard manifest.entries[0].outcome == .quarantined else {
                for index in requests.indices.dropFirst() {
                    mark(&manifest, index, .skipped, SkipReason.appNotMoved.description)
                }
                try store.write(manifest)
                return RemovalReport(manifest: manifest)
            }
        }

        var adminIndices: [Int] = []
        for (index, request) in requests.enumerated() where index >= firstIndex {
            if request.rule.needs(.admin) && request.rule.effectiveDeleteMode != .immediate {
                mark(&manifest, index, .skipped, SkipReason.adminRequiresImmediate.description)
            } else if let reason = checker.check(request.item, rule: request.rule) {
                mark(&manifest, index, .skipped, reason.description)
            } else if request.rule.needs(.admin) {
                adminIndices.append(index)
            } else {
                perform(index, request, &manifest, quarantineDevice: quarantineDevice)
            }
            if (index + 1) % Self.checkpointInterval == 0 { try store.write(manifest) }
        }
        runAdminBatch(adminIndices, requests, &manifest)
        try store.write(manifest)
        return RemovalReport(manifest: manifest)
    }

    private func perform(
        _ index: Int, _ request: RemovalRequest, _ manifest: inout SessionManifest, quarantineDevice: Int32?
    ) {
        let fileManager = FileManager.default
        let path = request.item.path
        do {
            switch request.rule.effectiveDeleteMode {
            case .immediate:
                if request.rule.makeWritable && !request.rule.needs(.admin) {
                    try WritableTree.prepare(path, device: request.item.device, inode: request.item.inode)
                }
                try fileManager.removeItem(atPath: path)
                mark(&manifest, index, .deleted, nil)
            case .quarantine:
                if let quarantineDevice, deviceOf(path) == quarantineDevice,
                    let stored = manifest.entries[index].storedPath
                {
                    try fileManager.createDirectory(
                        atPath: (stored as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try fileManager.moveItem(atPath: path, toPath: stored)
                    mark(&manifest, index, .quarantined, nil)
                } else {
                    manifest.entries[index].storedPath = try trash(path)
                    mark(&manifest, index, .trashed, nil)
                }
            }
        } catch {
            mark(&manifest, index, .failed, error.localizedDescription)
        }
    }

    /// Moves the app bundle (entry 0) into its planned quarantine location with one administrator prompt.
    /// The outcome is decided by what is on disk afterwards, not only by the prompt's exit status.
    private func moveBundleAsAdmin(
        _ request: RemovalRequest, _ manifest: inout SessionManifest, _ plan: AdminBundleMove,
        itemsDirectory: String, quarantineDevice: Int32?
    ) {
        let path = request.item.path
        guard let stored = manifest.entries[0].storedPath, request.rule.effectiveDeleteMode == .quarantine else {
            mark(&manifest, 0, .failed, "no quarantine location for the app")
            return
        }
        guard let quarantineDevice, deviceOf(path) == quarantineDevice else {
            mark(&manifest, 0, .failed, "the app is on a different volume from quarantine")
            return
        }
        do {
            try FileManager.default.createDirectory(
                atPath: (stored as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        } catch {
            mark(&manifest, 0, .failed, error.localizedDescription)
            return
        }
        let move: AppBundleAdminMove
        do {
            move = try AppBundleAdminMove(
                source: path, destination: stored, bundleID: plan.bundleID,
                applicationFolders: plan.applicationFolders, sessionItemsDirectory: itemsDirectory,
                protectedPaths: plan.protectedPaths)
        } catch {
            mark(&manifest, 0, .failed, "\(error)")
            return
        }
        let problem: String?
        switch plan.executor.runAsAdmin(move) {
        case .cancelled:
            mark(&manifest, 0, .failed, SkipReason.adminCancelled.description)
            return
        case .succeeded: problem = nil
        case .failed(let message): problem = message
        }
        // The root script only stages the bundle; the final move into quarantine is ours (as the user).
        switch move.finishAsUser() {
        case .moved:
            markAfterBundleMove(&manifest, move: move, problem: problem)
        case .notMoved:
            mark(&manifest, 0, .failed, problem ?? "the app is still in place after the administrator move")
        case .stranded(let whereabouts):
            mark(&manifest, 0, .failed, problem.map { "\($0); \(whereabouts)" } ?? whereabouts)
        }
    }

    /// Quarantined only when the original bundle (same device and inode) is a real directory at the
    /// stored path. Whatever is at the old path now doesn't matter: it is no longer the app.
    private func markAfterBundleMove(
        _ manifest: inout SessionManifest, move: AppBundleAdminMove, problem: String?
    ) {
        guard let moved = FileStat.of(move.destination), moved.isDirectory, !moved.isSymlink,
            moved.device == move.sourceDevice, moved.inode == move.sourceInode
        else {
            mark(&manifest, 0, .failed, problem ?? "the app did not arrive in quarantine")
            return
        }
        var notes: [String] = []
        if let problem { notes.append("moved, but: \(problem)") }
        if moved.ownerUID != getuid() {
            notes.append("still owned by another user; restoring may need an administrator")
        }
        mark(&manifest, 0, .quarantined, notes.isEmpty ? nil : notes.joined(separator: "; "))
    }

    private func runAdminBatch(_ indices: [Int], _ requests: [RemovalRequest], _ manifest: inout SessionManifest) {
        var batch: [Int] = []
        var length = 0
        for index in indices {
            let path = requests[index].item.path
            if (try? AdminCommandBuilder.removalCommand(paths: [path])) == nil {
                mark(&manifest, index, .skipped, SkipReason.adminUnsupportedPath.description)
                continue
            }
            if !parentIsProtected(path) {
                mark(&manifest, index, .skipped, SkipReason.adminUnsafeParent.description)
                continue
            }
            let quotedLength = AdminCommandBuilder.shellQuote(path).utf8.count + 1
            if length + quotedLength > AdminCommandBuilder.maxCommandLength - 64 {
                mark(&manifest, index, .skipped, SkipReason.adminBatchFull.description)
                continue
            }
            length += quotedLength
            batch.append(index)
        }
        guard !batch.isEmpty else { return }

        let command: RemovalCommand
        do {
            command = try AdminCommandBuilder.removalCommand(paths: batch.map { requests[$0].item.path })
        } catch {
            for index in batch { mark(&manifest, index, .failed, "\(error)") }
            return
        }
        switch admin.runAsAdmin(command) {
        case .succeeded:
            for index in batch {
                markAfterAdminRun(
                    &manifest, index, requests[index].item.path,
                    presentMessage: "still present after administrator removal")
            }
        case .cancelled:
            for index in batch { mark(&manifest, index, .skipped, SkipReason.adminCancelled.description) }
        case .failed(let message):
            // rm may have removed some items before failing; report what is actually gone.
            for index in batch {
                markAfterAdminRun(&manifest, index, requests[index].item.path, presentMessage: message)
            }
        }
    }

    /// Deleted only when lstat fails with ENOENT; any other lstat failure means removal is unverified.
    private func markAfterAdminRun(
        _ manifest: inout SessionManifest, _ index: Int, _ path: String, presentMessage: String
    ) {
        var info = stat()
        if lstat(path, &info) == 0 {
            mark(&manifest, index, .failed, presentMessage)
        } else if errno == ENOENT {
            mark(&manifest, index, .deleted, nil)
        } else {
            mark(&manifest, index, .failed, "could not verify removal")
        }
    }

    private func mark(_ manifest: inout SessionManifest, _ index: Int, _ outcome: EntryOutcome, _ reason: String?) {
        manifest.entries[index].outcome = outcome
        manifest.entries[index].reason = reason
        // A planned stored path is only meaningful if the item actually moved there.
        if outcome == .skipped || outcome == .failed {
            manifest.entries[index].storedPath = nil
        }
    }
}
