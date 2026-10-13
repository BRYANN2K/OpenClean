import Foundation
import Probes
import Quarantine
import RuleKit
import ScanEngine
import TestSupport
import Testing

@testable import OpenCleanKit

/// Settings → Project folders through the coordinator: scan, clean, and the removal-time re-check.
struct CoordinatorProjectFoldersTests {
    let nodeRule = Rule(
        id: NodeModulesProbe.id, name: "node", category: .developer, explain: "x", probe: NodeModulesProbe.id,
        safety: .review)

    func coordinator(_ home: TempDirectory) throws -> OpenCleanCoordinator {
        OpenCleanCoordinator(
            home: home.path, environment: ["OPENCLEAN_RULES_DIR": try FixtureRules.writeDirectory(in: home)],
            registry: ProbeRegistry([NodeModulesProbe(index: ProjectArtifactIndex())]),
            processChecker: FakeProcessChecker(), openFiles: FakeOpenFiles(), admin: FakeAdminExecutor(),
            fullDiskAccess: { .granted }, trash: { _ in nil })
    }

    /// A JavaScript project under `relative` whose files were all last changed 60 days ago.
    func staleProject(_ home: TempDirectory, _ relative: String) throws {
        try home.file("\(relative)/package.json", bytes: 10)
        try home.file("\(relative)/src/index.js", bytes: 10)
        try home.file("\(relative)/node_modules/dep/index.js", bytes: 1_000)
        let old = Date().addingTimeInterval(-60 * 86_400)
        let root = home.path + "/" + relative
        let paths = try FileManager.default.subpathsOfDirectory(atPath: root).map { root + "/" + $0 } + [root]
        for path in paths.sorted(by: { $0.count > $1.count }) {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }
    }

    @Test func findsAndQuarantinesArtifactsInAChosenDocumentsFolder() async throws {
        let home = try TempDirectory()
        try staleProject(home, "Documents/Code/app")
        let subject = try coordinator(home)
        #expect(await subject.scan([nodeRule], settings: Settings()).allItems.isEmpty)

        let settings = Settings(projectFolders: ["~/Documents/Code"])
        try subject.settingsStore.save(settings)
        let result = await subject.scan([nodeRule], settings: settings)
        let modules = home.path + "/Documents/Code/app/node_modules"
        #expect(result.allItems.map(\.path) == [modules])

        let report = try subject.execute(CleanupPlan(result: result, selectedPaths: [modules]))
        #expect(report.manifest.entries.map(\.outcome) == [.quarantined])
        #expect(!FileManager.default.fileExists(atPath: modules))
        #expect(FileManager.default.fileExists(atPath: home.path + "/Documents/Code/app/src/index.js"))

        // Restorable like any other quarantined item.
        let restored = try subject.restore(sessionID: report.manifest.id, onConflict: .skip)
        #expect(restored.restored == [modules])
    }

    @Test func removingTheFolderFromSettingsWithdrawsTheExemptionAtRemoval() async throws {
        let home = try TempDirectory()
        try staleProject(home, "Documents/Code/app")
        let subject = try coordinator(home)
        let settings = Settings(projectFolders: ["~/Documents/Code"])
        try subject.settingsStore.save(settings)
        let result = await subject.scan([nodeRule], settings: settings)
        let modules = home.path + "/Documents/Code/app/node_modules"
        #expect(result.allItems.map(\.path) == [modules])

        try subject.settingsStore.save(Settings())
        let report = try subject.execute(CleanupPlan(result: result, selectedPaths: [modules]))
        #expect(report.manifest.entries.map(\.outcome) == [.skipped])
        #expect(report.skipped.first?.reason?.hasPrefix("protected (inside protected location") == true)
        #expect(FileManager.default.fileExists(atPath: modules))
    }

    @Test func explainsWhyAFolderCantBeAdded() throws {
        let home = try TempDirectory()
        let outside = try TempDirectory()
        try home.directory("Documents/Code")
        try home.directory(".ssh")
        let subject = try coordinator(home)
        #expect(subject.projectFolderProblem(home.path + "/Documents/Code") == nil)
        #expect(subject.projectFolderProblem("~/Documents/Code") == nil)
        #expect(subject.projectFolderProblem(home.path)?.contains("already searched") == true)
        #expect(subject.projectFolderProblem(outside.path) != nil)
        #expect(subject.projectFolderProblem(home.path + "/.ssh") != nil)
        #expect(subject.projectFolderProblem(home.path + "/missing") == "That folder doesn't exist.")
    }

    @Test func settingsKeepProjectFoldersAndReadOldFiles() throws {
        let home = try TempDirectory()
        let store = SettingsStore(url: home.url.appendingPathComponent("settings.json"))
        try store.save(Settings(projectFolders: ["~/Documents/Code"]))
        #expect(store.load().projectFolders == ["~/Documents/Code"])
        try Data(#"{"excludedPaths": ["~/x"]}"#.utf8).write(to: store.url)
        #expect(store.load() == Settings(excludedPaths: ["~/x"]))
    }
}
