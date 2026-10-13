import Foundation
import RuleKit
import ScanEngine
import TestSupport
import Testing

@testable import Probes

/// Fixture files are created "now"; scanning with `now` 60 days ahead makes every project look
/// untouched for 60 days. A project is made recent by giving one of its files a date close to `later`.
struct ProjectArtifactsProbeTests {
    static let later = Date().addingTimeInterval(60 * 86_400)

    func context(_ home: TempDirectory, excludes: [String] = [], now: Date = Self.later) -> ScanContext {
        ScanContext(
            home: home.path, hasFullDiskAccess: true, processChecker: FakeProcessChecker(), userExcludes: excludes,
            now: now)
    }

    func paths(_ probe: some Probe, _ home: TempDirectory, excludes: [String] = []) async throws -> [String] {
        try await probe.scan(context(home, excludes: excludes)).map(\.path)
    }

    func nodeProject(_ home: TempDirectory, _ relative: String) throws {
        try home.file("\(relative)/package.json", bytes: 10)
        try home.file("\(relative)/src/index.js", bytes: 10)
        try home.file("\(relative)/node_modules/left-pad/index.js", bytes: 1_000)
    }

    @Test func findsNodeModulesInAStaleProject() async throws {
        let home = try TempDirectory()
        try nodeProject(home, "Developer/app")
        let findings = try await NodeModulesProbe(index: ProjectArtifactIndex()).scan(context(home))
        #expect(findings.map(\.path) == [home.path + "/Developer/app/node_modules"])
        let hint = try #require(findings.first?.hint)
        #expect(hint.hasPrefix("~/Developer/app, unchanged for "))
        #expect(hint.contains("npm install"))
        #expect(findings.allSatisfy { !$0.reportOnly })
    }

    @Test func skipsRecentlyChangedProjects() async throws {
        let home = try TempDirectory()
        try nodeProject(home, "Developer/active")
        try nodeProject(home, "Developer/old")
        // A file one level down was saved yesterday (relative to the scan).
        try FileManager.default.setAttributes(
            [.modificationDate: Self.later.addingTimeInterval(-86_400)],
            ofItemAtPath: home.path + "/Developer/active/src/index.js")
        #expect(
            try await paths(NodeModulesProbe(index: ProjectArtifactIndex()), home) == [
                home.path + "/Developer/old/node_modules"
            ])
    }

    @Test func recentGitActivityKeepsAProject() async throws {
        let home = try TempDirectory()
        try nodeProject(home, "code/app")
        try home.file("code/app/.git/index", bytes: 10, modified: Self.later.addingTimeInterval(-3_600))
        #expect(try await paths(NodeModulesProbe(index: ProjectArtifactIndex()), home).isEmpty)
    }

    @Test func anActiveEnclosingRepositoryKeepsNestedPackages() async throws {
        let home = try TempDirectory()
        try home.file("code/mono/package.json", bytes: 10)
        try home.file("code/mono/.git/index", bytes: 10, modified: Self.later.addingTimeInterval(-3_600))
        try nodeProject(home, "code/mono/packages/web/app")
        #expect(try await paths(NodeModulesProbe(index: ProjectArtifactIndex()), home).isEmpty)
    }

    @Test func respectsTheStalenessOption() async throws {
        let home = try TempDirectory()
        try nodeProject(home, "Developer/app")
        let strict = NodeModulesProbe(options: ProjectScanOptions(staleAfterDays: 90), index: ProjectArtifactIndex())
        #expect(try await paths(strict, home).isEmpty)
    }

    @Test func needsThePackageManifest() async throws {
        let home = try TempDirectory()
        try home.file("Developer/loose/node_modules/x/index.js", bytes: 100)
        try home.file("Developer/rusty/target/debug/app", bytes: 100)
        #expect(try await paths(NodeModulesProbe(index: ProjectArtifactIndex()), home).isEmpty)
        #expect(try await paths(RustTargetProbe(index: ProjectArtifactIndex()), home).isEmpty)
    }

    @Test func neverFollowsSymlinks() async throws {
        let home = try TempDirectory()
        let outside = try TempDirectory()
        try home.file("Developer/linked/package.json", bytes: 10)
        try outside.file("modules/x/index.js", bytes: 100)
        try home.symlink("Developer/linked/node_modules", to: outside.path + "/modules")
        try nodeProject(outside, "project")
        try home.symlink("Developer/elsewhere", to: outside.path + "/project")
        #expect(try await paths(NodeModulesProbe(index: ProjectArtifactIndex()), home).isEmpty)
    }

    @Test func skipsProtectedHiddenAndLibraryFolders() async throws {
        let home = try TempDirectory()
        try nodeProject(home, "Documents/app")
        try nodeProject(home, "Desktop/app")
        try nodeProject(home, "Downloads/app")
        try nodeProject(home, "Library/app")
        try nodeProject(home, ".hidden/app")
        try nodeProject(home, "Developer/Tool.app/Contents/app")
        try nodeProject(home, "Developer/ok")
        #expect(
            try await paths(NodeModulesProbe(index: ProjectArtifactIndex()), home) == [
                home.path + "/Developer/ok/node_modules"
            ])
    }

    @Test func skipsUserExclusions() async throws {
        let home = try TempDirectory()
        try nodeProject(home, "Developer/keep")
        try nodeProject(home, "Developer/old")
        let found = try await paths(
            NodeModulesProbe(index: ProjectArtifactIndex()), home, excludes: [home.path + "/Developer/keep"])
        #expect(found == [home.path + "/Developer/old/node_modules"])
    }

    @Test func doesNotLookInsideFoundArtifacts() async throws {
        let home = try TempDirectory()
        try nodeProject(home, "Developer/app")
        try nodeProject(home, "Developer/app/node_modules/dep")
        #expect(
            try await paths(NodeModulesProbe(index: ProjectArtifactIndex()), home) == [
                home.path + "/Developer/app/node_modules"
            ])
    }

    @Test func respectsTheDepthLimit() async throws {
        let home = try TempDirectory()
        try nodeProject(home, "a/b/c/d/app")
        let shallow = NodeModulesProbe(options: ProjectScanOptions(maxDepth: 3), index: ProjectArtifactIndex())
        #expect(try await paths(shallow, home).isEmpty)
        #expect(try await paths(NodeModulesProbe(index: ProjectArtifactIndex()), home).count == 1)
    }

    @Test func findsVirtualEnvironmentsByTheirConfigFile() async throws {
        let home = try TempDirectory()
        try home.file("Developer/py/pyproject.toml", bytes: 10)
        try home.file("Developer/py/.venv/pyvenv.cfg", bytes: 10)
        try home.file("Developer/py/.venv/lib/site.py", bytes: 100)
        try home.file("Developer/py/env-without-cfg/lib/site.py", bytes: 100)
        try home.file("Developer/script-only/venv/pyvenv.cfg", bytes: 10)
        #expect(
            try await paths(PythonVirtualEnvProbe(index: ProjectArtifactIndex()), home) == [
                home.path + "/Developer/py/.venv", home.path + "/Developer/script-only/venv",
            ])
    }

    /// `python -m venv .` inside a project puts `pyvenv.cfg` next to the source code. That folder is the
    /// project, not a disposable environment, and must never be reported as one.
    @Test func neverTakesAProjectWithAVenvAtItsRootForAVirtualEnv() async throws {
        let home = try TempDirectory()
        try home.file("Developer/thesis/pyvenv.cfg", bytes: 10)
        try home.file("Developer/thesis/bin/python", bytes: 10)
        try home.file("Developer/thesis/analysis.py", bytes: 10)
        try home.file("Developer/thesis/.git/HEAD", bytes: 10)
        try home.file("Developer/tool/pyvenv.cfg", bytes: 10)
        try home.file("Developer/tool/pyproject.toml", bytes: 10)
        try home.file("Developer/tool/.venv/pyvenv.cfg", bytes: 10)
        #expect(
            try await paths(PythonVirtualEnvProbe(index: ProjectArtifactIndex()), home) == [
                home.path + "/Developer/tool/.venv"
            ])
        #expect(!ProjectArtifactSignature.isVirtualEnv(home.path + "/Developer/thesis"))
        #expect(!ProjectArtifactSignature.isVirtualEnv(home.path + "/Developer/tool"))
        #expect(ProjectArtifactSignature.isVirtualEnv(home.path + "/Developer/tool/.venv"))
    }

    @Test func findsRustTargets() async throws {
        let home = try TempDirectory()
        try home.file("Developer/crate/Cargo.toml", bytes: 10)
        try home.file("Developer/crate/target/debug/crate", bytes: 100)
        #expect(
            try await paths(RustTargetProbe(index: ProjectArtifactIndex()), home) == [
                home.path + "/Developer/crate/target"
            ])
    }

    @Test func findsBuildOutputsOnlyNextToTheirToolsFile() async throws {
        let home = try TempDirectory()
        try home.file("Developer/swift/Package.swift", bytes: 10)
        try home.file("Developer/swift/.build/debug/x", bytes: 10)
        try home.file("Developer/maven/pom.xml", bytes: 10)
        try home.file("Developer/maven/target/classes/A.class", bytes: 10)
        try home.file("Developer/gradle/build.gradle.kts", bytes: 10)
        try home.file("Developer/gradle/build/libs/a.jar", bytes: 10)
        try home.file("Developer/gradle/.gradle/8.0/x", bytes: 10)
        try home.file("Developer/web/package.json", bytes: 10)
        try home.file("Developer/web/.next/cache/x", bytes: 10)
        try home.file("Developer/plain/build/report.pdf", bytes: 10)
        try home.file("Developer/plain/.next/x", bytes: 10)
        let found = try await paths(ProjectBuildOutputProbe(index: ProjectArtifactIndex()), home)
        #expect(
            Set(found) == [
                home.path + "/Developer/swift/.build", home.path + "/Developer/maven/target",
                home.path + "/Developer/gradle/build", home.path + "/Developer/gradle/.gradle",
                home.path + "/Developer/web/.next",
            ])
    }

    @Test func pythonToolCachesNeedACacheDirTag() async throws {
        let home = try TempDirectory()
        try home.file("Developer/py/pyproject.toml", bytes: 10)
        let tagged = try home.file(
            "Developer/py/.mypy_cache/CACHEDIR.TAG",
            bytes: 0)
        try Data("Signature: 8a477f597d28d172789f06886806bc55\n# mypy".utf8).write(to: URL(fileURLWithPath: tagged))
        try home.file("Developer/py/.pytest_cache/v/cache/lastfailed", bytes: 10)
        try home.file("Developer/py/.ruff_cache/CACHEDIR.TAG", bytes: 10)  // wrong content
        #expect(
            try await paths(ProjectBuildOutputProbe(index: ProjectArtifactIndex()), home) == [
                home.path + "/Developer/py/.mypy_cache"
            ])
    }

    @Test func probesShareOneWalkPerScan() async throws {
        let home = try TempDirectory()
        try nodeProject(home, "Developer/app")
        let index = ProjectArtifactIndex()
        let ctx = context(home)
        #expect(try await NodeModulesProbe(index: index).scan(ctx).count == 1)
        // Created after the walk: the same scan (same context) does not see it.
        try home.file("Developer/crate/Cargo.toml", bytes: 10)
        try home.file("Developer/crate/target/x", bytes: 10)
        #expect(try await RustTargetProbe(index: index).scan(ctx).isEmpty)
        let nextScan = context(home, now: Self.later.addingTimeInterval(1))
        #expect(try await RustTargetProbe(index: index).scan(nextScan).count == 1)
    }

    @Test func scanEngineTurnsFindingsIntoCanonicalReviewItems() async throws {
        let home = try TempDirectory()
        try nodeProject(home, "Developer/app")
        try nodeProject(home, "Documents/app")
        let rule = Rule(
            id: NodeModulesProbe.id, name: "node", category: .developer, explain: "x", probe: NodeModulesProbe.id,
            safety: .review)
        let engine = ScanEngine(registry: ProbeRegistry([NodeModulesProbe(index: ProjectArtifactIndex())]))
        let result = await engine.scan([rule], context: context(home))
        let items = try #require(result.rule(rule.id)).items
        #expect(items.map(\.path) == [home.path + "/Developer/app/node_modules"])
        #expect(items.allSatisfy { !$0.reportOnly && $0.size > 0 && realPath($0.path) == $0.path })
    }
}
