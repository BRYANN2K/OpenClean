import AppInventory
import Foundation
import Quarantine
import RuleKit

/// Uninstaller entry points: list apps, find leftovers, move an app and its leftovers to quarantine.
extension OpenCleanCoordinator {
    /// True when running against a pretend home (`OPENCLEAN_HOME`, or a test's temp home).
    var usesPretendHome: Bool {
        let real = NSHomeDirectory()
        return canonicalPathKey(resolvedHome) != canonicalPathKey(realPath(real) ?? real)
    }

    /// Where apps are listed. With a pretend home only `<home>/Applications` is used, so dev runs and tests
    /// never list or act on the real `/Applications`.
    public var applicationFolders: [ApplicationFolder] {
        usesPretendHome
            ? [ApplicationFolder(path: resolvedHome + "/Applications", allowsUninstall: true)]
            : ApplicationFolder.standard(home: resolvedHome)
    }

    /// OpenClean's own bundle and data, which the Uninstaller must never offer to remove.
    var uninstallProtectedPaths: [String] { [Bundle.main.bundlePath, paths.support.path] }

    public func installedApps(
        folders: [ApplicationFolder]? = nil, lastUsed: (any LastUsedProvider)? = MdlsLastUsedProvider(),
        progress: AsyncStream<AppInventoryProgress>.Continuation? = nil
    ) async -> [InstalledApp] {
        await AppInventory(
            folders: folders ?? applicationFolders, processChecker: processChecker, lastUsed: lastUsed,
            protectedPaths: [Bundle.main.bundlePath]
        ).scan(progress: progress)
    }

    /// Leftovers in `~/Library` (removable) and `systemLibrary` (report-only). Empty without a bundle id.
    public func leftovers(
        for app: InstalledApp, otherBundleIDs: Set<String> = [], systemLibrary: String = "/Library"
    ) -> [Leftover] {
        guard let bundleID = app.bundleID else { return [] }
        return LeftoverFinder(home: resolvedHome, systemLibrary: systemLibrary)
            .find(bundleID: bundleID, names: app.matchNames, otherBundleIDs: otherBundleIDs)
    }

    /// Moves `app` and the given user-scope leftovers into one quarantine session. Report-only leftovers
    /// are ignored. Refuses (moving nothing) unless the app is still exactly as listed and safe to move.
    public func uninstall(
        _ app: InstalledApp, leftovers: [Leftover], folders: [ApplicationFolder]? = nil
    ) throws -> UninstallOutcome {
        guard let bundleID = app.bundleID else { return .refused(.invalidBundleID) }
        switch app.status {
        case .removable: break
        case .appleApp: return .refused(.appleApp)
        case .openClean: return .refused(.openClean)
        case .needsAdministrator: return .refused(.needsAdministrator)
        case .listOnly: return .refused(.outsideApplicationFolders)
        case .noBundleID: return .refused(.invalidBundleID)
        }
        let allowed = (folders ?? applicationFolders).filter(\.allowsUninstall).map(\.path)
        let request = UninstallRequest(
            bundle: app.scanItem(ruleID: UninstallService.appRuleID), bundleID: bundleID,
            leftovers: leftovers.filter { !$0.isReportOnly }.map {
                $0.scanItem(ruleID: UninstallService.leftoverRuleID)
            }
        )
        let openPaths = try? openFiles.openPaths()
        let service = UninstallService(
            store: store, denyList: DenyList(home: resolvedHome), processChecker: processChecker, admin: admin,
            trash: trash)
        return try service.uninstall(
            request, allowedFolders: allowed, protectedBundleIDs: [InstalledApp.openCleanBundleID],
            protectedPaths: uninstallProtectedPaths, openPaths: openPaths)
    }
}
