import Darwin
import Foundation
import RuleKit
import ScanEngine

public enum SelfUpdateError: Error, Equatable, CustomStringConvertible {
    case notAnApp(String)
    case translocated
    case symlinkedPath(String)
    case developmentBuild(String)
    case readOnlyVolume(String)
    case notWritable(String)
    case wrongBundle(String)
    case stagedOutsideUpdates(String)
    case differentVolume(String)
    case moveFailed(String)
    /// Installing the new version failed; the previous version was put back where it was.
    case installFailedRolledBack(String)
    /// Installing failed and the previous version could not be moved back; it is in History.
    case installFailedKeptInHistory(String)

    public var description: String {
        switch self {
        case .notAnApp(let path): "\(path) is not an app bundle"
        case .translocated:
            "macOS is running OpenClean from a temporary, read-only location (App Translocation). Move OpenClean to your Applications folder and open it from there."
        case .symlinkedPath(let path): "\(path) is reached through a symbolic link"
        case .developmentBuild(let path): "\(path) is a development build"
        case .readOnlyVolume(let path): "\(path) is on a read-only volume"
        case .notWritable(let path): "you don't have permission to replace \(path)"
        case .wrongBundle(let path): "\(path) is not OpenClean"
        case .stagedOutsideUpdates(let path): "\(path) is not inside OpenClean's Updates folder"
        case .differentVolume(let path): "\(path) is on a different volume from OpenClean's quarantine"
        case .moveFailed(let reason): "could not move the current version to quarantine: \(reason)"
        case .installFailedRolledBack(let reason):
            "the new version could not be installed (\(reason)); the current version was left in place"
        case .installFailedKeptInHistory(let reason):
            "the new version could not be installed (\(reason)); the previous version is in History and can be restored from there"
        }
    }
}

/// The only code that moves the running OpenClean.app. It swaps in a staged update and keeps the old
/// version as a quarantine session, so History → Restore can bring it back.
///
/// Order: validate both bundles → write the intent (`update.previous-version`, pending) to a new
/// session manifest → move the current app into the session's `items/` (same volume only, so this is a
/// rename) → move the staged app to the original path. If that second move fails, the old app is moved
/// back and the entry marked failed. Nothing is ever deleted here.
public struct SelfUpdateReplacer: Sendable {
    public static let ruleID = "update.previous-version"

    let store: QuarantineStore
    /// `<support>/Updates`, symlinks resolved.
    let updatesDirectory: String
    let bundleIdentifier: String
    let move: @Sendable (String, String) throws -> Void
    let isReadOnlyVolume: @Sendable (String) -> Bool
    let isWritable: @Sendable (String) -> Bool

    public init(
        store: QuarantineStore, updatesDirectory: URL, bundleIdentifier: String,
        move: @escaping @Sendable (String, String) throws -> Void = {
            try FileManager.default.moveItem(atPath: $0, toPath: $1)
        },
        isReadOnlyVolume: @escaping @Sendable (String) -> Bool = SelfUpdateReplacer.volumeIsReadOnly,
        isWritable: @escaping @Sendable (String) -> Bool = { access($0, W_OK) == 0 }
    ) {
        self.store = store
        self.updatesDirectory = realPath(updatesDirectory.path) ?? updatesDirectory.path
        self.bundleIdentifier = bundleIdentifier
        self.move = move
        self.isReadOnlyVolume = isReadOnlyVolume
        self.isWritable = isWritable
    }

    /// Swaps `stagedApp` in at `currentApp`. Returns the session holding the previous version.
    @discardableResult
    public func replace(currentApp: String, with stagedApp: String, now: Date = .now) throws -> SessionManifest {
        try preflight(currentApp: currentApp)
        try validateStagedApp(stagedApp)
        let fileManager = FileManager.default

        var manifest = try store.createSession(now: now)
        let stored = store.itemsDirectory(manifest.id).appendingPathComponent("0")
            .appendingPathComponent((currentApp as NSString).lastPathComponent).path
        manifest.entries = [
            ManifestEntry(
                id: 0, originalPath: currentApp, storedPath: stored,
                size: FileSizer.allocatedSize(of: currentApp, ledger: HardLinkLedger()), ruleID: Self.ruleID,
                mode: .quarantine, outcome: .pending, reason: nil)
        ]
        try store.write(manifest)

        do {
            try fileManager.createDirectory(
                atPath: (stored as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try move(currentApp, stored)
        } catch {
            manifest.entries[0].outcome = .failed
            manifest.entries[0].storedPath = nil
            manifest.entries[0].reason = error.localizedDescription
            try? store.write(manifest)
            throw SelfUpdateError.moveFailed(error.localizedDescription)
        }

        do {
            try move(stagedApp, currentApp)
        } catch {
            let reason = error.localizedDescription
            if (try? move(stored, currentApp)) != nil {
                manifest.entries[0].outcome = .failed
                manifest.entries[0].storedPath = nil
                manifest.entries[0].reason = "update not installed: \(reason)"
                try? store.write(manifest)
                throw SelfUpdateError.installFailedRolledBack(reason)
            }
            manifest.entries[0].outcome = .quarantined
            manifest.entries[0].reason = "update not installed: \(reason)"
            try? store.write(manifest)
            throw SelfUpdateError.installFailedKeptInHistory(reason)
        }
        manifest.entries[0].outcome = .quarantined
        try store.write(manifest)
        return manifest
    }

    /// Everything `replace` checks about the running app before touching it, including that it shares a
    /// volume with the quarantine store. Creates the quarantine folder if needed; moves nothing.
    public func preflight(currentApp: String) throws {
        try validateCurrentApp(currentApp)
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        guard let stat = FileStat.of(currentApp), FileStat.of(store.root.path)?.device == stat.device else {
            throw SelfUpdateError.differentVolume(currentApp)
        }
    }

    /// The running app must be a plain, writable `.app` with OpenClean's bundle id: absolute and
    /// canonical, no symlink anywhere in its path, not translocated, not a development build, on a
    /// writable volume, with a parent folder you can write to.
    public func validateCurrentApp(_ path: String) throws {
        guard path.utf8.first == 0x2F, !hasNonCanonicalComponent(path),
            (path as NSString).pathExtension.lowercased() == "app"
        else { throw SelfUpdateError.notAnApp(path) }
        if path.contains("/AppTranslocation/") { throw SelfUpdateError.translocated }
        guard let stat = FileStat.of(path), stat.isDirectory, !stat.isSymlink else {
            throw SelfUpdateError.notAnApp(path)
        }
        guard let resolved = realPath(path), canonicalPathKey(resolved) == canonicalPathKey(path) else {
            throw SelfUpdateError.symlinkedPath(path)
        }
        if resolved.contains("/AppTranslocation/") { throw SelfUpdateError.translocated }
        if Self.isDevelopmentBuild(path) { throw SelfUpdateError.developmentBuild(path) }
        guard Self.bundleIdentifier(of: path) == bundleIdentifier else { throw SelfUpdateError.wrongBundle(path) }
        if isReadOnlyVolume(path) { throw SelfUpdateError.readOnlyVolume(path) }
        let parent = (path as NSString).deletingLastPathComponent
        guard isWritable(parent), isWritable(path) else { throw SelfUpdateError.notWritable(path) }
    }

    /// The staged app must be a real `.app` directory inside `<support>/Updates` with OpenClean's bundle id.
    public func validateStagedApp(_ path: String) throws {
        guard path.utf8.first == 0x2F, !hasNonCanonicalComponent(path),
            (path as NSString).pathExtension.lowercased() == "app"
        else { throw SelfUpdateError.notAnApp(path) }
        guard let stat = FileStat.of(path), stat.isDirectory, !stat.isSymlink else {
            throw SelfUpdateError.notAnApp(path)
        }
        guard let resolved = realPath(path), canonicalPathKey(resolved) == canonicalPathKey(path),
            canonicalPathKey(resolved) != canonicalPathKey(updatesDirectory),
            pathIsWithin(canonicalPathKeyString(resolved), canonicalPathKeyString(updatesDirectory))
        else { throw SelfUpdateError.stagedOutsideUpdates(path) }
        guard Self.bundleIdentifier(of: path) == bundleIdentifier else { throw SelfUpdateError.wrongBundle(path) }
    }

    /// Byte-level containment on canonical keys (case-folded, NFD).
    private func canonicalPathKeyString(_ path: String) -> String {
        String(decoding: canonicalPathKey(path), as: UTF8.self)
    }

    /// A `.build` folder anywhere in the path, or a SwiftPM checkout around it (`<repo>/build/OpenClean.app`
    /// with `<repo>/Package.swift`): replacing those would fight the developer's own build.
    static func isDevelopmentBuild(_ path: String) -> Bool {
        if path.utf8.split(separator: 0x2F).contains(where: { $0.elementsEqual(".build".utf8) }) { return true }
        let parent = (path as NSString).deletingLastPathComponent
        let grandparent = (parent as NSString).deletingLastPathComponent
        return FileStat.of((grandparent as NSString).appendingPathComponent("Package.swift")) != nil
    }

    static func bundleIdentifier(of app: String) -> String? {
        let plist = URL(fileURLWithPath: app).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return dictionary["CFBundleIdentifier"] as? String
    }

    public static let volumeIsReadOnly: @Sendable (String) -> Bool = { path in
        var info = statfs()
        guard statfs(path, &info) == 0 else { return true }
        return (info.f_flags & UInt32(MNT_RDONLY)) != 0
    }
}
