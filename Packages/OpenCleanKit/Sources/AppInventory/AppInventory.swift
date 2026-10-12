import Darwin
import Foundation
import RuleKit
import ScanEngine

/// Lists `.app` bundles directly inside the given folders. Read-only: it never changes anything on disk.
public struct AppInventory: Sendable {
    let folders: [ApplicationFolder]
    let processChecker: any ProcessChecker
    let lastUsed: (any LastUsedProvider)?
    /// Bundles that are OpenClean itself (normally `Bundle.main.bundlePath`).
    let protectedPaths: [String]

    public init(
        folders: [ApplicationFolder], processChecker: any ProcessChecker = RunningProcessChecker(),
        lastUsed: (any LastUsedProvider)? = MdlsLastUsedProvider(), protectedPaths: [String] = []
    ) {
        self.folders = folders
        self.processChecker = processChecker
        self.lastUsed = lastUsed
        self.protectedPaths = protectedPaths
    }

    struct Candidate: Sendable {
        let path: String
        let allowsUninstall: Bool
    }

    public func scan(progress: AsyncStream<AppInventoryProgress>.Continuation? = nil) async -> [InstalledApp] {
        defer { progress?.finish() }
        let candidates = listCandidates()
        progress?.yield(AppInventoryProgress(finished: 0, total: candidates.count))

        let running: @Sendable (String) -> Bool
        if processChecker is RunningProcessChecker {
            let snapshot = RunningProcessChecker.runningBundleIDs()
            running = { snapshot.contains($0) }
        } else {
            let checker = processChecker
            running = { checker.isRunning(bundleID: $0) }
        }
        let protectedKeys = protectedPaths.map { canonicalPathKey(realPath($0) ?? $0) }

        var apps: [InstalledApp] = []
        await withTaskGroup(of: InstalledApp?.self) { group in
            for candidate in candidates {
                group.addTask {
                    Self.describe(candidate, isRunning: running, protectedKeys: protectedKeys)
                }
            }
            var finished = 0
            for await app in group {
                finished += 1
                if let app { apps.append(app) }
                progress?.yield(AppInventoryProgress(finished: finished, total: candidates.count))
            }
        }

        apps.sort { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
        }
        if let lastUsed, !Task.isCancelled {
            let dates = lastUsed.lastUsedDates(for: apps.map(\.path))
            apps = apps.map { $0.with(lastUsed: dates[$0.path]) }
        }
        return apps
    }

    /// `*.app` directory entries of every folder, canonical and de-duplicated. Symlinked entries are skipped.
    func listCandidates() -> [Candidate] {
        var seen = Set<[UInt8]>()
        var candidates: [Candidate] = []
        let suffix = Array(".app".utf8)
        for folder in folders {
            guard let resolved = realPath(folder.path), FileStat.of(resolved)?.isDirectory == true,
                let names = try? FileManager.default.contentsOfDirectory(atPath: resolved)
            else { continue }
            for name in names.sorted() where isSafeComponent(name) {
                let key = canonicalNameKey(name)
                guard key.count > suffix.count, key.suffix(suffix.count).elementsEqual(suffix) else { continue }
                let path = resolved + "/" + name
                guard let stat = FileStat.of(path), stat.isDirectory, !stat.isSymlink else { continue }
                guard seen.insert(canonicalPathKey(path)).inserted else { continue }
                candidates.append(Candidate(path: path, allowsUninstall: folder.allowsUninstall))
            }
        }
        return candidates
    }

    static func describe(
        _ candidate: Candidate, isRunning: @Sendable (String) -> Bool, protectedKeys: [[UInt8]]
    ) -> InstalledApp? {
        let path = candidate.path
        guard let stat = FileStat.of(path), stat.isDirectory, !stat.isSymlink else { return nil }
        let info = readInfo(path)
        let fileName = (path as NSString).lastPathComponent
        let name = (fileName as NSString).deletingPathExtension
        let bundleID = (info["CFBundleIdentifier"] as? String).flatMap { isSafeComponent($0) ? $0 : nil }
        let bundleName = (info["CFBundleName"] as? String).flatMap { isSafeComponent($0) ? $0 : nil }
        let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String)
        let parent = (path as NSString).deletingLastPathComponent
        let writable = access(path, W_OK) == 0 && access(parent, W_OK) == 0
        let size = FileSizer.allocatedSize(of: path, ledger: HardLinkLedger())

        let status: AppStatus
        if pathIsWithin(path, "/System", caseInsensitive: true) || isAppleBundleID(bundleID) {
            status = .appleApp
        } else if isOpenClean(bundleID) || protectedKeys.contains(canonicalPathKey(path)) {
            status = .openClean
        } else if bundleID == nil {
            status = .noBundleID
        } else if !candidate.allowsUninstall {
            status = .listOnly
        } else if stat.ownerUID == 0 || !writable {
            status = .needsAdministrator
        } else {
            status = .removable
        }

        return InstalledApp(
            path: path, name: name, bundleName: bundleName == name ? nil : bundleName, bundleID: bundleID,
            version: version, size: size, device: stat.device, inode: stat.inode,
            modificationDate: stat.modificationDate, ownerUID: stat.ownerUID,
            isRunning: bundleID.map(isRunning) ?? false, isWritable: writable, lastUsed: nil, status: status)
    }

    static func readInfo(_ bundle: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: bundle + "/Contents/Info.plist"),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return plist
    }

    public static func isAppleBundleID(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID.lowercased().starts(with: "com.apple.")
    }

    public static func isOpenClean(_ bundleID: String?) -> Bool {
        bundleID?.lowercased() == InstalledApp.openCleanBundleID.lowercased()
    }
}

extension InstalledApp {
    func with(lastUsed: Date?) -> InstalledApp {
        InstalledApp(
            path: path, name: name, bundleName: bundleName, bundleID: bundleID, version: version, size: size,
            device: device, inode: inode, modificationDate: modificationDate, ownerUID: ownerUID,
            isRunning: isRunning, isWritable: isWritable, lastUsed: lastUsed, status: status)
    }
}
