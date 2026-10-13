import Foundation
import RuleKit
import ScanEngine
import TestSupport
import Testing

@testable import Probes

/// Project folders the user chose (Settings → Project folders), and stopping the walk when a scan is
/// cancelled. Like `ProjectArtifactsProbeTests`, scans run 60 days "later" so fixture projects look stale.
struct ProjectFoldersAndCancellationTests {
    static let later = Date().addingTimeInterval(60 * 86_400)

    func context(
        _ home: TempDirectory, projectFolders: [String] = [], excludes: [String] = [], now: Date = Self.later
    ) -> ScanContext {
        ScanContext(
            home: home.path, hasFullDiskAccess: true, processChecker: FakeProcessChecker(), userExcludes: excludes,
            projectFolders: projectFolders, now: now)
    }

    func nodeProject(_ home: TempDirectory, _ relative: String) throws {
        try home.file("\(relative)/package.json", bytes: 10)
        try home.file("\(relative)/src/index.js", bytes: 10)
        try home.file("\(relative)/node_modules/left-pad/index.js", bytes: 1_000)
    }

    let nodeRule = Rule(
        id: NodeModulesProbe.id, name: "node", category: .developer, explain: "x", probe: NodeModulesProbe.id,
        safety: .review)

    // MARK: Project folders

    @Test func documentsAndDesktopAreSearchedOnlyWhenChosen() async throws {
        let home = try TempDirectory()
        try nodeProject(home, "Documents/Code/app")
        try nodeProject(home, "Desktop/site")
        try nodeProject(home, "Documents/Letters/not-chosen")
        let probe = NodeModulesProbe(index: ProjectArtifactIndex())
        #expect(try await probe.scan(context(home)).isEmpty)

        let chosen = [home.path + "/Documents/Code", home.path + "/Desktop"]
        let found = try await probe.scan(context(home, projectFolders: chosen)).map(\.path)
        #expect(
            Set(found) == [
                home.path + "/Documents/Code/app/node_modules", home.path + "/Desktop/site/node_modules",
            ])
    }

    @Test func aChosenFolderCanBeAProjectItself() async throws {
        let home = try TempDirectory()
        try nodeProject(home, "Documents/app")
        let found = try await NodeModulesProbe(index: ProjectArtifactIndex())
            .scan(context(home, projectFolders: [home.path + "/Documents/app"])).map(\.path)
        #expect(found == [home.path + "/Documents/app/node_modules"])
    }

    @Test func refusedFoldersAreIgnored() async throws {
        let home = try TempDirectory()
        let outside = try TempDirectory()
        try nodeProject(outside, "app")
        try nodeProject(home, "Library/Mobile Documents/com~apple~CloudDocs/app")
        let ctx = context(
            home,
            projectFolders: [
                outside.path, home.path + "/Library/Mobile Documents/com~apple~CloudDocs", home.path,
            ])
        #expect(ctx.projectFolders.isEmpty)
        #expect(try await NodeModulesProbe(index: ProjectArtifactIndex()).scan(ctx).isEmpty)
    }

    @Test func exclusionsStillApplyInsideChosenFolders() async throws {
        let home = try TempDirectory()
        try nodeProject(home, "Documents/Code/keep")
        try nodeProject(home, "Documents/Code/old")
        let found = try await NodeModulesProbe(index: ProjectArtifactIndex()).scan(
            context(
                home, projectFolders: [home.path + "/Documents/Code"],
                excludes: [home.path + "/Documents/Code/keep"])
        ).map(\.path)
        #expect(found == [home.path + "/Documents/Code/old/node_modules"])
    }

    @Test func anActiveRepositoryAboveAChosenFolderKeepsItsPackages() async throws {
        let home = try TempDirectory()
        try home.file("Documents/mono/package.json", bytes: 10)
        try home.file("Documents/mono/.git/index", bytes: 10, modified: Self.later.addingTimeInterval(-3_600))
        try nodeProject(home, "Documents/mono/packages/web")
        let found = try await NodeModulesProbe(index: ProjectArtifactIndex())
            .scan(context(home, projectFolders: [home.path + "/Documents/mono/packages"]))
        #expect(found.isEmpty)
    }

    @Test func overlappingFoldersReportEachArtifactOnce() async throws {
        let home = try TempDirectory()
        try nodeProject(home, "Code/app")
        try nodeProject(home, "Documents/Code/app")
        let found = try await NodeModulesProbe(index: ProjectArtifactIndex()).scan(
            context(
                home,
                projectFolders: [home.path + "/Code", home.path + "/Documents", home.path + "/Documents/Code"])
        ).map(\.path)
        #expect(
            found.sorted() == [home.path + "/Code/app/node_modules", home.path + "/Documents/Code/app/node_modules"])
    }

    @Test func scanEngineKeepsOnlyArtifactsFromChosenFolders() async throws {
        let home = try TempDirectory()
        try nodeProject(home, "Documents/Code/app")
        let engine = ScanEngine(registry: ProbeRegistry([NodeModulesProbe(index: ProjectArtifactIndex())]))
        let result = await engine.scan(
            [nodeRule], context: context(home, projectFolders: [home.path + "/Documents/Code"]))
        let items = try #require(result.rule(nodeRule.id)).items
        #expect(items.map(\.path) == [home.path + "/Documents/Code/app/node_modules"])
        #expect(items.allSatisfy { !$0.reportOnly })

        // The same finding from a rule that would delete immediately is dropped as protected.
        var immediate = nodeRule
        immediate.safety = .regenerable
        let dropped = await engine.scan(
            [immediate], context: context(home, projectFolders: [home.path + "/Documents/Code"]))
        #expect(try #require(dropped.rule(immediate.id)).items.isEmpty)
        #expect(try #require(dropped.rule(immediate.id)).errors.contains { $0.contains("protected") })
    }

    @Test func everyArtifactTheWalkFindsMatchesTheRemovalTimeSignature() throws {
        let home = try TempDirectory()
        try nodeProject(home, "Documents/js")
        try home.file("Documents/rs/Cargo.toml")
        try home.file("Documents/rs/target/x")
        try home.file("Documents/py/.venv/pyvenv.cfg")
        try home.file("Documents/sw/Package.swift")
        try home.file("Documents/sw/.build/x")
        try home.file("Documents/mvn/pom.xml")
        try home.file("Documents/mvn/target/x")
        try home.file("Documents/gr/settings.gradle")
        try home.file("Documents/gr/.gradle/x")
        try home.file("Documents/fl/pubspec.yaml")
        try home.file("Documents/fl/build/x")
        try home.file("Documents/fl/.dart_tool/x")
        try home.file("Documents/js/.svelte-kit/x")
        let artifacts = ProjectArtifactFinder().find(
            home: home.path, denyList: DenyList(home: home.path), excludes: [],
            projectFolders: [home.path + "/Documents"])
        #expect(artifacts.count == 9)
        for artifact in artifacts {
            #expect(ProjectArtifactSignature.matches(artifact.path), "\(artifact.path)")
        }
    }

    // MARK: Cancellation

    @Test func theWalkStopsAsSoonAsItIsCancelled() throws {
        let home = try TempDirectory()
        for index in 0..<40 { try nodeProject(home, "Developer/app\(index)") }
        let finder = ProjectArtifactFinder()
        let all = finder.find(home: home.path, denyList: DenyList(home: home.path), excludes: [])
        #expect(all.count == 40)

        var asked = 0
        let partial = finder.find(home: home.path, denyList: DenyList(home: home.path), excludes: []) {
            asked += 1
            return asked > 5
        }
        // Five folders listed: home, Developer and at most three projects.
        #expect(partial.count <= 3)
        #expect(asked == 6)

        let none = finder.find(home: home.path, denyList: DenyList(home: home.path), excludes: []) { true }
        #expect(none.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheScanCancelsTheSharedWalk() async throws {
        let home = try TempDirectory()
        try nodeProject(home, "Developer/app")
        let walks = Counter()
        // The first walk runs until it is cancelled (it would hang the test otherwise); later ones finish.
        let index = ProjectArtifactIndex { context, options in
            if walks.next() == 1 {
                while !Task.isCancelled { usleep(1_000) }
                return []
            }
            return ProjectArtifactFinder(options: options).find(
                home: context.home, denyList: context.denyList, excludes: context.userExcludes)
        }
        let ctx = context(home)
        let task = Task { try await NodeModulesProbe(index: index).scan(ctx) }
        while walks.value == 0 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        // The cancelled walk is not reused: the next scan with the same context gets full results.
        #expect(try await NodeModulesProbe(index: index).scan(ctx).count == 1)
        #expect(walks.value == 2)
    }

    @Test func aScanCancelledBeforeItStartsNeverWalks() async throws {
        let home = try TempDirectory()
        let walks = Counter()
        let index = ProjectArtifactIndex { _, _ in
            _ = walks.next()
            return []
        }
        let ctx = context(home)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NodeModulesProbe(index: index).scan(ctx)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(walks.value == 0)
    }

    @Test func aCancelledScanEngineRunReportsTheProbeAsCancelled() async throws {
        let home = try TempDirectory()
        for index in 0..<20 { try nodeProject(home, "Developer/app\(index)") }
        let engine = ScanEngine(registry: ProbeRegistry([NodeModulesProbe(index: ProjectArtifactIndex())]))
        let rule = nodeRule
        let ctx = context(home)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.scan([rule], context: ctx)
        }
        let result = await task.value
        #expect(!result.isComplete)
        #expect(result.rule(rule.id)?.items.isEmpty == true)
    }
}

/// A thread-safe counter for walks started from detached tasks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
