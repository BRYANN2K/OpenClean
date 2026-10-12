import Foundation
import Quarantine
import RuleKit
import SpaceKit

/// Space Lens: read-only scans plus the user-initiated move to the Trash.
extension OpenCleanCoordinator {
    /// The resolved home every Space Lens scan and safety check uses.
    public var spaceLensHome: String { resolvedHome }

    public var trashPolicy: TrashPolicy { TrashPolicy(home: resolvedHome) }

    /// Downloads, Desktop, Documents, Pictures, Movies and Music, where they exist (canonical paths).
    public var defaultDuplicateRoots: [String] {
        ["Downloads", "Desktop", "Documents", "Pictures", "Movies", "Music"]
            .compactMap { realPath(resolvedHome + "/" + $0) }
    }

    /// Size tree of `root` (default: home). nil when the folder doesn't exist.
    public func scanSpace(
        root: String? = nil, options: SpaceScanOptions = SpaceScanOptions(),
        progress: AsyncStream<SpaceScanProgress>.Continuation? = nil
    ) async -> SpaceScanResult? {
        guard let canonical = realPath(root ?? resolvedHome) else { return nil }
        return await SpaceScanner(options: options).scan(root: canonical, progress: progress)
    }

    public func findLargeFiles(
        roots: [String]? = nil, options: LargeFileOptions = LargeFileOptions(),
        progress: AsyncStream<FinderProgress>.Continuation? = nil
    ) async -> LargeFileResult {
        await LargeFileFinder(policy: trashPolicy, options: options)
            .find(roots: roots ?? [resolvedHome], progress: progress)
    }

    public func findDuplicates(
        roots: [String]? = nil, options: DuplicateOptions = DuplicateOptions(),
        progress: AsyncStream<FinderProgress>.Continuation? = nil
    ) async -> DuplicateResult {
        await DuplicateFinder(policy: trashPolicy, options: options)
            .find(roots: roots ?? defaultDuplicateRoots, progress: progress)
    }

    /// Moves user-picked items to the Trash after re-checking each one (policy, scan root, changes,
    /// open files). Blocking: runs `lsof` once. Call it off the main actor.
    public func moveToTrash(_ requests: [TrashRequest]) -> TrashReport {
        let openPaths = try? openFiles.openPaths()
        return TrashMover(policy: trashPolicy, openPaths: openPaths, trash: trash).move(requests)
    }
}
