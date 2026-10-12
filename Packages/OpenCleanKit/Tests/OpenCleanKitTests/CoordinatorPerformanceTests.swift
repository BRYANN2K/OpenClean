import Foundation
import Maintenance
import ScanEngine
import TestSupport
import Testing

@testable import OpenCleanKit

struct CoordinatorPerformanceTests {
    func coordinator(_ home: TempDirectory) -> OpenCleanCoordinator {
        OpenCleanCoordinator(
            home: home.path, environment: [:], registry: ProbeRegistry([]), processChecker: FakeProcessChecker(),
            openFiles: FakeOpenFiles(), admin: FakeAdminExecutor(), fullDiskAccess: { .granted }, trash: { _ in nil })
    }

    @Test func injectedRemovalOnlyExecutorRefusesMaintenanceInsteadOfPrompting() throws {
        let home = try TempDirectory()
        let runner = coordinator(home).maintenanceRunner(runner: FakeCommandRunner())
        #expect(runner.run(.flushDNSCache) == .failed("no administrator executor is configured"))
    }

    @Test func explicitMaintenanceExecutorIsUsed() throws {
        let home = try TempDirectory()
        let admin = FakeMaintenanceAdminExecutor()
        let runner = coordinator(home).maintenanceRunner(runner: FakeCommandRunner(), admin: admin)
        #expect(runner.run(.reindexSpotlight) == .succeeded)
        #expect(admin.commands == [.reindexSpotlight])
    }

    @Test func pathsComeFromTheCoordinatorHome() throws {
        let home = try TempDirectory()
        let subject = coordinator(home)
        #expect(
            subject.maintenanceHistory.url.path == home.path + "/Library/Application Support/OpenClean/maintenance.json"
        )
        #expect(subject.applicationDirectories == ["/Applications", home.path + "/Applications"])
        #expect(LaunchItemRoots.standard(home: home.path).userAgents == home.path + "/Library/LaunchAgents")
    }

    @Test func loginItemsServiceReadsTheFakeHomeOnly() throws {
        let home = try TempDirectory()
        let agents = try home.directory("Library/LaunchAgents")
        try PropertyListSerialization.data(fromPropertyList: ["Label": "a.b.c"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: agents + "/a.b.c.plist"))
        let empty = try home.directory("empty")
        let service = coordinator(home).loginItemsService(
            runner: FakeCommandRunner(),
            roots: LaunchItemRoots(userAgents: agents, systemAgents: empty, systemDaemons: empty), installedApps: [])
        #expect(service.inventory().items.map(\.label) == ["a.b.c"])
    }
}
