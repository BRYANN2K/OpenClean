import Foundation
import RuleKit

public enum LaunchAgentQuarantineError: Error, Equatable, CustomStringConvertible {
    case notInAgentsDirectory(String)
    case notARegularFile(String)
    case notOwnedByUser(String)
    case differentVolume(String)
    case moveFailed(String)

    public var description: String {
        switch self {
        case .notInAgentsDirectory(let path): "\(path) is not directly inside your LaunchAgents folder"
        case .notARegularFile(let path): "\(path) is not a regular property list file"
        case .notOwnedByUser(let path): "\(path) is not owned by you"
        case .differentVolume(let path): "\(path) is on a different volume from OpenClean's quarantine"
        case .moveFailed(let reason): "could not move the file to quarantine: \(reason)"
        }
    }
}

/// Moves one user launch agent plist into a new quarantine session, so History → Restore can put it back.
/// Never deletes and never uses the Trash: if the plist can't be moved within the volume, nothing happens.
public struct LaunchAgentQuarantine: Sendable {
    public static let ruleID = "performance.launch-agent"

    let store: QuarantineStore
    /// `<home>/Library/LaunchAgents`, symlinks resolved.
    let agentsDirectory: String
    let currentUID: UInt32

    public init(store: QuarantineStore, agentsDirectory: String, currentUID: UInt32 = getuid()) {
        self.store = store
        self.agentsDirectory = realPath(agentsDirectory) ?? agentsDirectory
        self.currentUID = currentUID
    }

    /// Validates `plistPath`, writes the intent to a new session manifest, then moves the file.
    @discardableResult
    public func quarantine(plistPath: String, now: Date = .now) throws -> SessionManifest {
        try validate(plistPath)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: store.root, withIntermediateDirectories: true)
        guard let stat = FileStat.of(plistPath), FileStat.of(store.root.path)?.device == stat.device else {
            throw LaunchAgentQuarantineError.differentVolume(plistPath)
        }

        var manifest = try store.createSession(now: now)
        let stored = store.itemsDirectory(manifest.id).appendingPathComponent("0")
            .appendingPathComponent((plistPath as NSString).lastPathComponent).path
        manifest.entries = [
            ManifestEntry(
                id: 0, originalPath: plistPath, storedPath: stored, size: max(stat.allocatedBytes, 0),
                ruleID: Self.ruleID, mode: .quarantine, outcome: .pending, reason: nil)
        ]
        try store.write(manifest)

        do {
            try fileManager.createDirectory(
                atPath: (stored as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fileManager.moveItem(atPath: plistPath, toPath: stored)
        } catch {
            manifest.entries[0].outcome = .failed
            manifest.entries[0].storedPath = nil
            manifest.entries[0].reason = error.localizedDescription
            try? store.write(manifest)
            throw LaunchAgentQuarantineError.moveFailed(error.localizedDescription)
        }
        manifest.entries[0].outcome = .quarantined
        try store.write(manifest)
        return manifest
    }

    /// The plist must be a regular file you own, directly inside the (resolved) LaunchAgents folder.
    func validate(_ path: String) throws {
        guard path.utf8.first == 0x2F, !hasNonCanonicalComponent(path),
            (path as NSString).pathExtension == "plist",
            canonicalPathKey((path as NSString).deletingLastPathComponent) == canonicalPathKey(agentsDirectory)
        else { throw LaunchAgentQuarantineError.notInAgentsDirectory(path) }
        guard let stat = FileStat.of(path), !stat.isSymlink, !stat.isDirectory else {
            throw LaunchAgentQuarantineError.notARegularFile(path)
        }
        guard stat.ownerUID == currentUID else { throw LaunchAgentQuarantineError.notOwnedByUser(path) }
    }
}
