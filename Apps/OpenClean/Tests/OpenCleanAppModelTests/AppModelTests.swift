import Foundation
import OpenCleanKit
import Permissions
import RuleKit
import ScanEngine
import Testing
import TestSupport
@testable import OpenCleanAppModel

struct SlowAppProbe: Probe {
    static let id = "slow.app-probe"
    func scan(_ context: ScanContext) async throws -> [ProbeFinding] {
        try await Task.sleep(for: .seconds(30))
        return []
    }
}

@MainActor
struct AppModelTests {
    func makeModel(_ home: TempDirectory, registry: ProbeRegistry = ProbeRegistry([])) throws -> AppModel {
        let rules = try FixtureRules.writeDirectory(in: home)
        let coordinator = OpenCleanCoordinator(
            home: home.path, environment: ["OPENCLEAN_RULES_DIR": rules], registry: registry,
            processChecker: FakeProcessChecker(), openFiles: FakeOpenFiles(), admin: FakeAdminExecutor(),
            fullDiskAccess: { .granted }, trash: { _ in nil })
        let suite = "openclean.appmodel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppModel(
            coordinator: coordinator, signatureTracker: SignatureTracker(defaults: defaults, currentSignature: "test"))
    }

    @Test func launchLoadsRulesAccessAndHistory() throws {
        let home = try TempDirectory()
        let model = try makeModel(home)
        model.onLaunch()
        #expect(model.loadedRules.rules.count == 2)
        #expect(model.accessAdvice == .ok)
        #expect(model.history.isEmpty)
        #expect(model.phase == .idle)
    }

    @Test func scanSelectsRegenerableItemsByDefault() async throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/com.example/blob", bytes: 4_096)
        try home.file("Downloads/old.dmg", bytes: 4_096)
        let model = try makeModel(home)
        model.onLaunch()
        model.startScan()
        await model.waitForScan()

        #expect(model.phase == .results)
        #expect(model.selectedPaths == [home.path + "/Library/Caches/com.example"])
        let downloads = try #require(model.result?.rule("fixture.downloads"))
        #expect(model.state(of: downloads) == .off)
        #expect(model.state(of: .user) == .mixed)
        model.setSelected(true, category: .user)
        #expect(model.state(of: .user) == .on)
        model.toggle(try #require(downloads.items.first))
        #expect(model.state(of: downloads) == .off)
    }

    @Test func cleanRemovesSelectionAndRecordsHistory() async throws {
        let home = try TempDirectory()
        let cache = try home.file("Library/Caches/com.example/blob", bytes: 4_096)
        let model = try makeModel(home)
        model.onLaunch()
        model.startScan()
        await model.waitForScan()
        await model.clean()

        #expect(model.phase == .finished)
        #expect(!FileManager.default.fileExists(atPath: cache))
        #expect(model.history.count == 1)
        #expect(model.result?.rule("fixture.caches")?.items.isEmpty == true)
        #expect(model.selectedPaths.isEmpty)
        #expect((model.lastReport?.deletedBytes ?? 0) >= 4_096)
    }

    @Test func restoreFromHistory() async throws {
        let home = try TempDirectory()
        let download = try home.file("Downloads/old.dmg", bytes: 10)
        let model = try makeModel(home)
        model.onLaunch()
        model.startScan()
        await model.waitForScan()
        model.selectedPaths = [download]
        await model.clean()
        #expect(!FileManager.default.fileExists(atPath: download))

        let session = try #require(model.history.first?.id)
        let report = await model.restore(sessionID: session, paths: nil, onConflict: .skip)
        #expect(report?.restored == [download])
        #expect(FileManager.default.fileExists(atPath: download))
    }

    @Test func cancelScanShowsPartialResults() async throws {
        let home = try TempDirectory()
        let model = try makeModel(home, registry: ProbeRegistry([SlowAppProbe()]))
        let userRules = model.paths.userRules.path
        try FileManager.default.createDirectory(atPath: userRules, withIntermediateDirectories: true)
        try """
        pack: slow
        version: 1
        rules:
          - id: slow.rule
            name: Slow
            category: developer
            explain: Takes forever.
            probe: slow.app-probe
            safety: review
        """.write(toFile: userRules + "/slow.yaml", atomically: true, encoding: .utf8)

        model.onLaunch()
        model.startScan()
        try await Task.sleep(for: .milliseconds(150))
        model.cancelScan()
        await model.waitForScan()

        #expect(model.phase == .results)
        #expect(model.result?.isComplete == false)
    }

    @Test func settingsPersistAndAdvancedTogglesCautionRules() throws {
        let home = try TempDirectory()
        let model = try makeModel(home)
        model.onLaunch()
        #expect(model.loadedRules.rules.count == 2)

        model.advancedEnabled = true
        model.retentionDays = 500
        model.addExclusion("/tmp/keep")
        #expect(model.loadedRules.rules.count == 3)
        #expect(model.retentionDays == 90)

        let reloaded = try makeModel(home)
        #expect(reloaded.settings == Settings(retentionDays: 90, advancedEnabled: true, excludedPaths: ["/tmp/keep"]))
        reloaded.removeExclusion("/tmp/keep")
        #expect(reloaded.settings.excludedPaths.isEmpty)
    }
}
