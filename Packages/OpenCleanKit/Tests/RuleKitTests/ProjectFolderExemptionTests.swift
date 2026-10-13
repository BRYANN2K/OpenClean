import Foundation
import TestSupport
import Testing

@testable import RuleKit

struct ProjectFolderExemptionTests {
    func rule(
        probe: String? = "node.project-modules", safety: SafetyLevel = .review, deleteMode: DeleteMode? = nil,
        requires: [Requirement] = []
    ) -> Rule {
        Rule(
            id: "node.project-modules", name: "N", category: .developer, explain: "x",
            paths: probe == nil ? ["~/x"] : [], probe: probe, safety: safety, deleteMode: deleteMode,
            requires: requires)
    }

    /// `~/Documents/Code/app` with a `package.json` and a `node_modules`.
    func documentsProject(_ home: TempDirectory) throws -> String {
        try home.file("Documents/Code/app/package.json", bytes: 10)
        try home.file("Documents/Code/app/node_modules/x/index.js", bytes: 10)
        return home.path + "/Documents/Code/app/node_modules"
    }

    func reason(_ home: TempDirectory, _ path: String) throws -> String {
        try #require(DenyList(home: home.path).denialReason(for: path))
    }

    // MARK: Which folders can be project folders

    @Test func acceptsFoldersInDocumentsDesktopAndHome() throws {
        let home = try TempDirectory()
        for folder in ["Documents/Code", "Documents", "Desktop/work", "Code", "Downloads/src"] {
            let path = try home.directory(folder)
            #expect(ProjectFolderExemption.problem(with: path, home: home.path) == nil, "\(folder)")
        }
    }

    @Test func refusesHomeOutsideProtectedAndLinkedFolders() throws {
        let temp = try TempDirectory()
        let home = try temp.directory("home")
        let outside = try temp.directory("elsewhere")
        let target = try temp.directory("home/Documents/real")
        let link = try temp.symlink("home/Code", to: target)
        let icloud = try temp.directory("home/Library/Mobile Documents/com~apple~CloudDocs/code")
        let ssh = try temp.directory("home/.ssh/keys")
        let support = try temp.directory("home/Library/Application Support/OpenClean/x")
        let file = try temp.file("home/notes.txt")
        for path in [home, outside, link, icloud, ssh, support, file, home + "/missing", "Documents/x"] {
            #expect(ProjectFolderExemption.problem(with: path, home: home) != nil, "\(path)")
        }
        #expect(ProjectFolderExemption.problem(with: home + "/Documents/../Documents", home: home) != nil)
        // Rejected folders never make it into an exemption.
        #expect(ProjectFolderExemption(home: home, folders: [home, outside, link, icloud]).folders.isEmpty)
    }

    // MARK: What the exemption lets through

    @Test func permitsAnArtifactInsideAChosenFolder() throws {
        let home = try TempDirectory()
        let modules = try documentsProject(home)
        let exemption = ProjectFolderExemption(home: home.path, folders: [home.path + "/Documents/Code"])
        #expect(exemption.permits(modules, deniedFor: try reason(home, modules), rule: rule()))
    }

    @Test func permitsEveryKindOfArtifactTheProbesReport() throws {
        let home = try TempDirectory()
        try home.file("Desktop/p/Cargo.toml")
        try home.directory("Desktop/p/target/debug")
        try home.file("Desktop/p/.venv/pyvenv.cfg")
        try home.file("Desktop/s/Package.swift")
        try home.directory("Desktop/s/.build")
        try home.file("Desktop/g/build.gradle")
        try home.directory("Desktop/g/build")
        try home.directory("Desktop/g/.gradle")
        try home.file("Desktop/w/package.json")
        try home.directory("Desktop/w/.next")
        try Data("Signature: 8a477f597d28d172789f06886806bc55\n".utf8).write(
            to: URL(fileURLWithPath: try home.directory("Desktop/w/.pytest_cache") + "/CACHEDIR.TAG"))
        let exemption = ProjectFolderExemption(home: home.path, folders: [home.path + "/Desktop"])
        for (relative, probe) in [
            ("p/target", "rust.project-targets"), ("p/.venv", "python.project-venvs"),
            ("s/.build", "dev.project-build-outputs"), ("g/build", "dev.project-build-outputs"),
            ("g/.gradle", "dev.project-build-outputs"), ("w/.next", "dev.project-build-outputs"),
            ("w/.pytest_cache", "dev.project-build-outputs"),
        ] {
            let path = home.path + "/Desktop/" + relative
            #expect(
                exemption.permits(path, deniedFor: try reason(home, path), rule: rule(probe: probe)), "\(relative)")
        }
    }

    /// Each probe's rule may only use the exemption for the kind of folder that probe reports: a
    /// `node_modules` rule can't remove a virtual environment, and so on.
    @Test func permitsOnlyWhatTheRulesOwnProbeReports() throws {
        let home = try TempDirectory()
        let modules = try documentsProject(home)
        try home.file("Documents/Code/app/.venv/pyvenv.cfg")
        try home.file("Documents/Code/crate/Cargo.toml")
        try home.directory("Documents/Code/crate/target")
        let venv = home.path + "/Documents/Code/app/.venv"
        let target = home.path + "/Documents/Code/crate/target"
        let exemption = ProjectFolderExemption(home: home.path, folders: [home.path + "/Documents/Code"])
        func permits(_ path: String, _ probe: String) throws -> Bool {
            exemption.permits(path, deniedFor: try reason(home, path), rule: rule(probe: probe))
        }
        #expect(try permits(modules, "node.project-modules"))
        #expect(try permits(venv, "python.project-venvs"))
        #expect(try permits(target, "rust.project-targets"))
        #expect(try !permits(venv, "node.project-modules"))
        #expect(try !permits(modules, "python.project-venvs"))
        #expect(try !permits(target, "dev.project-build-outputs"))
        #expect(try !permits(modules, "rust.project-targets"))
    }

    /// A project whose root holds a `pyvenv.cfg` (`python -m venv .`) is source code, not an artifact.
    @Test func neverPermitsAProjectThatHoldsAVenvAtItsRoot() throws {
        let home = try TempDirectory()
        try home.file("Documents/Code/thesis/pyvenv.cfg")
        try home.file("Documents/Code/thesis/analysis.py")
        try home.file("Documents/Code/thesis/.git/HEAD")
        let project = home.path + "/Documents/Code/thesis"
        let exemption = ProjectFolderExemption(home: home.path, folders: [home.path + "/Documents/Code"])
        #expect(
            !exemption.permits(project, deniedFor: try reason(home, project), rule: rule(probe: "python.project-venvs"))
        )
    }

    @Test func neverPermitsTheFolderItsAncestorsOrTheProtectedRoots() throws {
        let home = try TempDirectory()
        let modules = try documentsProject(home)
        // The user chose the node_modules folder itself, and its project, as project folders.
        let exemption = ProjectFolderExemption(
            home: home.path, folders: [modules, home.path + "/Documents/Code/app"])
        for path in [
            modules, home.path + "/Documents/Code/app", home.path + "/Documents/Code", home.path + "/Documents",
            home.path,
        ] {
            let why = DenyList(home: home.path).denialReason(for: path) ?? "none"
            #expect(!exemption.permits(path, deniedFor: why, rule: rule()), "\(path)")
        }
    }

    @Test func needsAChosenFolder() throws {
        let home = try TempDirectory()
        let modules = try documentsProject(home)
        try home.directory("Documents/Other")
        let why = try reason(home, modules)
        #expect(!ProjectFolderExemption(home: home.path, folders: []).permits(modules, deniedFor: why, rule: rule()))
        #expect(
            !ProjectFolderExemption(home: home.path, folders: [home.path + "/Documents/Other"])
                .permits(modules, deniedFor: why, rule: rule()))
    }

    @Test func needsAProjectProbeRuleThatQuarantines() throws {
        let home = try TempDirectory()
        let modules = try documentsProject(home)
        let why = try reason(home, modules)
        let exemption = ProjectFolderExemption(home: home.path, folders: [home.path + "/Documents/Code"])
        #expect(!exemption.permits(modules, deniedFor: why, rule: rule(probe: nil)))
        #expect(!exemption.permits(modules, deniedFor: why, rule: rule(probe: "xcode.simulators")))
        #expect(!exemption.permits(modules, deniedFor: why, rule: rule(safety: .regenerable)))
        #expect(!exemption.permits(modules, deniedFor: why, rule: rule(deleteMode: .immediate)))
        #expect(!exemption.permits(modules, deniedFor: why, rule: rule(requires: [.admin])))
    }

    @Test func onlyLooksPastTheDocumentsAndDesktopReasons() throws {
        let home = try TempDirectory()
        let modules = try documentsProject(home)
        let exemption = ProjectFolderExemption(home: home.path, folders: [home.path + "/Documents/Code"])
        for other in [
            "contains protected location \(home.path)/Documents", "inside protected location \(home.path)/.ssh",
            "protected location \(home.path)", "application bundle /Applications/X.app",
        ] {
            #expect(!exemption.permits(modules, deniedFor: other, rule: rule()), "\(other)")
        }
    }

    @Test func needsTheFileThatProvesWhichToolMadeIt() throws {
        let home = try TempDirectory()
        try home.file("Documents/Code/app/src/main.c")
        try home.directory("Documents/Code/app/node_modules")
        try home.directory("Documents/Code/app/target")
        try home.directory("Documents/Code/app/build")
        try home.directory("Documents/Code/app/.pytest_cache")
        try home.directory("Documents/Code/app/src")
        let exemption = ProjectFolderExemption(home: home.path, folders: [home.path + "/Documents/Code"])
        for name in ["node_modules", "target", "build", ".pytest_cache", "src"] {
            let path = home.path + "/Documents/Code/app/" + name
            #expect(!exemption.permits(path, deniedFor: try reason(home, path), rule: rule()), "\(name)")
        }
    }

    @Test func refusesSymlinksAndNonCanonicalPaths() throws {
        let home = try TempDirectory()
        _ = try documentsProject(home)
        let elsewhere = try home.directory("Documents/Elsewhere/modules")
        try home.file("Documents/Code/linked/package.json")
        let linked = try home.symlink("Documents/Code/linked/node_modules", to: elsewhere)
        let viaLink = try home.symlink("Documents/Code/alias", to: home.path + "/Documents/Code/app")
        let exemption = ProjectFolderExemption(home: home.path, folders: [home.path + "/Documents/Code"])
        for path in [
            linked, viaLink + "/node_modules", home.path + "/Documents/Code/app/../app/node_modules",
            "Documents/Code/app/node_modules",
        ] {
            let why = DenyList(home: home.path).denialReason(for: path) ?? ""
            #expect(!exemption.permits(path, deniedFor: why, rule: rule()), "\(path)")
        }
    }

    @Test func comparesFoldersCanonically() throws {
        let home = try TempDirectory()
        let modules = try documentsProject(home)
        // A differently cased spelling of the folder still counts, and the check stays byte-level:
        // "Code" + a combining mark is a different folder.
        let why = try reason(home, modules)
        let upper = ProjectFolderExemption(home: home.path, folders: [home.path + "/documents/code"])
        #expect(upper.folders.isEmpty || upper.permits(modules, deniedFor: why, rule: rule()))
        try home.directory("Documents/Code\u{301}")
        let other = ProjectFolderExemption(home: home.path, folders: [home.path + "/Documents/Code\u{301}"])
        #expect(!other.permits(modules, deniedFor: why, rule: rule()))
    }

    @Test func linterRefusesMakeWritableOutsideImmediateDeletes() {
        let linter = RuleLinter(home: "/Users/test", knownProbes: [])
        func issues(_ rule: Rule) -> [String] { linter.lint(rule, pack: "p").map(\.message) }
        var good = Rule(
            id: "go.module-cache", name: "Go", category: .developer, explain: "x", paths: ["~/go/pkg/mod"],
            safety: .regenerable, makeWritable: true)
        #expect(issues(good).isEmpty)
        good.safety = .review
        #expect(issues(good).contains { $0.contains("make_writable") })
        // A review or caution rule that deletes immediately still can't use it: only regenerable rules may.
        good.deleteMode = .immediate
        #expect(issues(good).contains { $0.contains("make_writable") })
        good.safety = .caution
        #expect(issues(good).contains { $0.contains("make_writable") })
        good.deleteMode = nil
        good.safety = .regenerable
        good.requires = [.admin]
        #expect(issues(good).contains { $0.contains("make_writable") })
    }
}
