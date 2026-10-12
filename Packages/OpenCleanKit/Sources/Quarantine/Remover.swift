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

    /// True when every ancestor directory of `path` (excluding "/") is a real directory (not a symlink)
    /// owned by root and not writable by the current user. Otherwise the same user could swap a parent
    /// for a symlink between validation and the root `rm`.
    public static let systemParentIsProtected: @Sendable (String) -> Bool = { path in
        let bytes = Array(path.utf8)
        for index in bytes.indices where index > 0 && bytes[index] == 0x2F {
            let ancestor = String(decoding: bytes[..<index], as: UTF8.self)
            guard let stat = FileStat.of(ancestor), !stat.isSymlink, stat.isDirectory,
                stat.ownerUID == 0, access(ancestor, W_OK) != 0
            else { return false }
        }
        return true
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

    public func remove(_ requests: [RemovalRequest], now: Date = .now) throws -> RemovalReport {
        var manifest = try store.createSession(now: now)
        let itemsDirectory = store.itemsDirectory(manifest.id)
        let quarantineDevice = deviceOf(itemsDirectory.path)

        // Record intent first: a crash after a move still leaves a restorable entry.
        manifest.entries = requests.enumerated().map { index, request in
            let mode = request.rule.effectiveDeleteMode
            let planned = mode == .quarantine && !request.rule.needs(.admin)
                ? itemsDirectory.appendingPathComponent("\(index)")
                    .appendingPathComponent((request.item.path as NSString).lastPathComponent).path
                : nil
            return ManifestEntry(
                id: index, originalPath: request.item.path, storedPath: planned, size: request.item.size,
                ruleID: request.rule.id, mode: mode, outcome: .pending, reason: nil)
        }
        try store.write(manifest)

        var adminIndices: [Int] = []
        for (index, request) in requests.enumerated() {
            if let reason = checker.check(request.item, rule: request.rule) {
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

    private func runAdminBatch(_ indices: [Int], _ requests: [RemovalRequest], _ manifest: inout SessionManifest) {
        var batch: [Int] = []
        var length = 0
        for index in indices {
            let path = requests[index].item.path
            if path.utf8.contains(where: { $0 == 0x0A || $0 == 0x0D }) {
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
                if FileStat.of(requests[index].item.path) == nil {
                    mark(&manifest, index, .deleted, nil)
                } else {
                    mark(&manifest, index, .failed, "still present after administrator removal")
                }
            }
        case .cancelled:
            for index in batch { mark(&manifest, index, .skipped, SkipReason.adminCancelled.description) }
        case .failed(let message):
            for index in batch { mark(&manifest, index, .failed, message) }
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
