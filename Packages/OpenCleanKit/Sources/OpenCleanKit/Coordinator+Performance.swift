import Foundation
import Maintenance
import Privilege
import ProcessKit
import Quarantine
import SystemMonitor

/// Performance module wiring: everything is derived from the coordinator's home (honours `OPENCLEAN_HOME`),
/// quarantine store and admin executor.
extension OpenCleanCoordinator {
    /// `/Applications` and `~/Applications`, where installed apps are looked up for owner resolution.
    public var applicationDirectories: [String] {
        ["/Applications", (home as NSString).appendingPathComponent("Applications")]
    }

    public func makeSystemMonitor() -> SystemMonitor {
        SystemMonitor(sampler: DarwinSampler(volume: URL(fileURLWithPath: home, isDirectory: true)))
    }

    public func loginItemsService(
        runner: any CommandRunner = ProcessCommandRunner(timeout: 10), roots: LaunchItemRoots? = nil,
        installedApps: [InstalledApp]? = nil
    ) -> LoginItemsService {
        LoginItemsService(
            roots: roots ?? .standard(home: home), runner: runner,
            installedApps: installedApps ?? InstalledApp.scan(directories: applicationDirectories),
            quarantineStore: store)
    }

    /// Admin tasks use the coordinator's executor when it can run maintenance commands; an injected
    /// executor that can't (e.g. a test fake for removals) refuses rather than falling back to a real prompt.
    public func maintenanceRunner(
        runner: any CommandRunner = ProcessCommandRunner(timeout: 300), admin: (any MaintenanceAdminExecutor)? = nil
    ) -> MaintenanceRunner {
        MaintenanceRunner(
            runner: runner, admin: admin ?? (self.admin as? any MaintenanceAdminExecutor) ?? RefusingMaintenanceAdmin())
    }

    public var maintenanceHistory: MaintenanceHistoryStore {
        MaintenanceHistoryStore(url: paths.support.appendingPathComponent("maintenance.json"))
    }

    /// Settings → General → Login Items (where macOS manages `SMAppService` items).
    public static let loginItemsSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
}

struct RefusingMaintenanceAdmin: MaintenanceAdminExecutor {
    func runAsAdmin(_ command: MaintenanceAdminCommand) -> AdminRunOutcome {
        .failed("no administrator executor is configured")
    }
}
