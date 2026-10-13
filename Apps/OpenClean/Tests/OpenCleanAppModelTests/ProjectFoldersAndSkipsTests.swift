import Foundation
import OpenCleanKit
import Permissions
import Quarantine
import RuleKit
import ScanEngine
import TestSupport
import Testing

@testable import OpenCleanAppModel

@MainActor
struct ProjectFoldersAndSkipsTests {
    func makeModel(_ home: TempDirectory) throws -> AppModel {
        let rules = try FixtureRules.writeDirectory(in: home)
        let coordinator = OpenCleanCoordinator(
            home: home.path, environment: ["OPENCLEAN_RULES_DIR": rules], registry: ProbeRegistry([]),
            processChecker: FakeProcessChecker(), openFiles: FakeOpenFiles(), admin: FakeAdminExecutor(),
            fullDiskAccess: { .granted }, trash: { _ in nil })
        let suite = "openclean.appmodel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppModel(
            coordinator: coordinator, signatureTracker: SignatureTracker(defaults: defaults, currentSignature: "test"))
    }

    @Test func projectFoldersPersistAndCanBeRemoved() throws {
        let home = try TempDirectory()
        let code = try home.directory("Documents/Code")
        let model = try makeModel(home)
        model.addProjectFolder(code)
        model.addProjectFolder(code)
        #expect(model.settings.projectFolders == [code])
        #expect(model.errorMessage == nil)
        #expect(try makeModel(home).settings.projectFolders == [code])
        model.removeProjectFolder(code)
        #expect(model.settings.projectFolders.isEmpty)
    }

    @Test func refusesFoldersThatCantBeProjectFolders() throws {
        let home = try TempDirectory()
        let outside = try TempDirectory()
        try home.directory(".ssh")
        let model = try makeModel(home)
        for path in [home.path, outside.path, home.path + "/.ssh", home.path + "/missing"] {
            model.errorMessage = nil
            model.addProjectFolder(path)
            #expect(model.errorMessage != nil, "\(path)")
        }
        #expect(model.settings.projectFolders.isEmpty)
    }

    @Test func changingProjectFoldersDiscardsResults() async throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/com.example/blob", bytes: 4_096)
        let code = try home.directory("Documents/Code")
        let model = try makeModel(home)
        model.onLaunch()
        model.startScan()
        await model.waitForScan()
        #expect(model.result != nil)
        model.addProjectFolder(code)
        #expect(model.phase == .idle)
        #expect(model.result == nil)

        model.startScan()
        await model.waitForScan()
        #expect(model.result != nil)
        model.removeProjectFolder(code)
        #expect(model.result == nil)
    }

    @Test func skippedItemsAreGroupedByReasonInPlainWords() {
        func entry(_ path: String, _ outcome: EntryOutcome, _ reason: String?) -> ManifestEntry {
            ManifestEntry(
                id: 0, originalPath: path, storedPath: nil, size: 1, ruleID: "r", mode: .immediate,
                outcome: outcome, reason: reason)
        }
        let skipped = SkippedItems(entries: [
            entry("/a", .skipped, SkipReason.changedSinceScan.description),
            entry("/b", .deleted, nil),
            entry("/c", .skipped, SkipReason.changedSinceScan.description),
            entry("/d", .skipped, SkipReason.inUse.description),
        ])
        #expect(skipped.count == 3)
        #expect(skipped.headline == "3 items were left in place")
        #expect(
            skipped.groups == [
                .init(explanation: "Changed since the scan; an app may be using it.", paths: ["/a", "/c"]),
                .init(explanation: "Open in another app. Quit the app, then scan again.", paths: ["/d"]),
            ])
        #expect(skipped.suggestsRescan)
        #expect(skipped.summary == "For different reasons; see the details.")

        let one = SkippedItems(entries: [entry("/p", .skipped, SkipReason.protected("x").description)])
        #expect(one.headline == "1 item was left in place")
        #expect(one.summary == "In a protected location. OpenClean never removes it.")
        #expect(!one.suggestsRescan)
    }

    @Test func aCleanThatSkipsAChangedItemExplainsIt() async throws {
        let home = try TempDirectory()
        let blob = try home.file("Library/Caches/com.example/blob", bytes: 4_096)
        let model = try makeModel(home)
        model.onLaunch()
        model.startScan()
        await model.waitForScan()
        // Something writes into the folder after the scan.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: (blob as NSString).deletingLastPathComponent)
        await model.clean()
        let report = try #require(model.lastReport)
        let skipped = SkippedItems(report: report)
        #expect(skipped.groups.map(\.explanation) == ["Changed since the scan; an app may be using it."])
        #expect(skipped.suggestsRescan)
        #expect(FileManager.default.fileExists(atPath: blob))
    }
}
