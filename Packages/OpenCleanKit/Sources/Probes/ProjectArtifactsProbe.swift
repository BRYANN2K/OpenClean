import Darwin
import Foundation
import RuleKit
import ScanEngine

/// What kind of regenerable folder a project holds.
public enum ProjectArtifactKind: String, Sendable, CaseIterable {
    /// `node_modules` next to a `package.json`.
    case nodeModules
    /// A Python virtual environment: any folder holding a `pyvenv.cfg`.
    case pythonVirtualEnv
    /// Cargo's `target` next to a `Cargo.toml`.
    case rustTarget
    /// Other build output and tool caches next to the file that proves which tool made them.
    case buildOutput
}

/// One regenerable folder inside a user project.
public struct ProjectArtifact: Sendable, Equatable {
    public let path: String
    public let kind: ProjectArtifactKind
    /// The folder that holds the artifact (where `package.json`, `Cargo.toml`, ... live).
    public let project: String
    /// Newest modification time seen in the project, its enclosing projects and the artifact itself.
    public let lastActivity: Date
    /// How to get the folder back, shown to the user.
    public let restore: String
}

/// Limits for the walk through the home folder.
public struct ProjectScanOptions: Sendable, Hashable {
    /// Projects changed more recently than this are left alone.
    public var staleAfterDays: Int
    /// How many folder levels below home are searched.
    public var maxDepth: Int
    /// Stop after listing this many folders, so a huge home can't make a scan run for minutes.
    public var maxDirectories: Int

    public init(staleAfterDays: Int = 30, maxDepth: Int = 8, maxDirectories: Int = 200_000) {
        self.staleAfterDays = staleAfterDays
        self.maxDepth = maxDepth
        self.maxDirectories = maxDirectories
    }
}

/// Finds regenerable folders inside the user's projects. Read-only: it lists folders, `lstat`s entries
/// and reads `CACHEDIR.TAG` files; it never follows a symlink, never crosses onto another volume and
/// never descends into hidden folders, deny-listed locations (Documents, Desktop, ...), the user's
/// exclusions, `~/Library`, the media folders, `~/Downloads`, app or library bundles, or the artifacts
/// it finds.
public struct ProjectArtifactFinder: Sendable {
    public let options: ProjectScanOptions

    public init(options: ProjectScanOptions = ProjectScanOptions()) {
        self.options = options
    }

    /// Folders directly in home that are never searched. Documents and Desktop are also deny-listed;
    /// listing Downloads or the media folders would trigger macOS privacy prompts for no benefit.
    static let skippedHomeFolders: Set<String> = [
        "Library", "Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures", "Applications",
        "Public",
    ]

    /// Folders that are never searched, wherever they are.
    static let skippedFolders: Set<String> = ["node_modules", "Pods", "Carthage", "DerivedData"]

    /// Package-like folders (bundles, libraries, archives) are never searched.
    static let skippedExtensions: Set<String> = [
        "app", "appex", "framework", "bundle", "plugin", "kext", "xcarchive", "xcodeproj", "xcworkspace",
        "playground", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx",
        "band", "sparsebundle", "dmg", "photolibrary", "lrdata", "noindex",
    ]

    /// Files whose presence makes a folder a project for the "enclosing project" activity check.
    static let projectMarkers: Set<String> = [
        ".git", "package.json", "Cargo.toml", "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt",
        "Pipfile", "Package.swift", "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle",
        "settings.gradle.kts", "pubspec.yaml", "go.mod", "Gemfile", "composer.json", "deno.json",
    ]

    static let cacheDirTagSignature = Array("Signature: 8a477f597d28d172789f06886806bc55".utf8)

    /// Every artifact found below `home` (which must be canonical), with its project's last activity.
    /// Staleness is not applied here; see `ProjectArtifactsScan.findings`.
    public func find(home: String, denyList: DenyList, excludes: [String]) -> [ProjectArtifact] {
        guard let homeStat = FileStat.of(home), homeStat.isDirectory, !homeStat.isSymlink else { return [] }
        var walk = Walk(finder: self, device: homeStat.device, denyList: denyList, excludes: excludes)
        walk.run(home: home)
        return walk.artifacts.sorted { $0.path < $1.path }
    }

    /// Classifies the children of one folder. `files` and `directories` are the folder's entries by
    /// name (real folders only: symlinks are in neither set).
    static func classify(
        directory: String, files: Set<String>, directories: Set<String>
    ) -> [(name: String, kind: ProjectArtifactKind, restore: String)] {
        var found: [(String, ProjectArtifactKind, String)] = []
        func has(_ name: String) -> Bool { files.contains(name) }

        if directories.contains("node_modules") && has("package.json") {
            found.append(
                (
                    "node_modules", .nodeModules,
                    "Your package manager's install command (npm install, pnpm install, yarn or bun install) recreates it."
                ))
        }
        if directories.contains("target") && has("Cargo.toml") {
            found.append(("target", .rustTarget, "cargo build recreates it."))
        }
        for name in directories.sorted() where !found.contains(where: { $0.0 == name }) {
            if isRegularFile(directory + "/" + name + "/pyvenv.cfg") {
                found.append(
                    (
                        name, .pythonVirtualEnv,
                        "Recreate it with python -m venv (or uv sync, poetry install) and reinstall the project's requirements."
                    ))
            }
        }

        var outputs: [(String, String)] = []
        if has("Package.swift") { outputs.append((".build", "swift build recreates it.")) }
        if has("pom.xml") && !has("Cargo.toml") { outputs.append(("target", "mvn package recreates it.")) }
        let gradle = has("build.gradle") || has("build.gradle.kts")
        let gradleSettings = gradle || has("settings.gradle") || has("settings.gradle.kts")
        if gradle { outputs.append(("build", "Gradle recreates it on the next build.")) }
        if gradleSettings { outputs.append((".gradle", "Gradle recreates it on the next build.")) }
        if has("pubspec.yaml") {
            outputs.append((".dart_tool", "dart pub get or flutter pub get recreates it."))
            if !gradle { outputs.append(("build", "flutter build or dart compile recreates it.")) }
        }
        if has("package.json") {
            for name in [".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular"] {
                outputs.append((name, "The framework recreates it on the next dev or build run."))
            }
        }
        for (name, restore) in outputs where directories.contains(name) && !found.contains(where: { $0.0 == name }) {
            found.append((name, .buildOutput, restore))
        }
        // Python tool caches carry a standard CACHEDIR.TAG; without one, the folder is not touched.
        for name in [".pytest_cache", ".mypy_cache", ".ruff_cache"] where directories.contains(name) {
            if hasCacheDirTag(directory + "/" + name) {
                found.append((name, .buildOutput, "The tool recreates it on its next run."))
            }
        }
        return found.map { (name: $0.0, kind: $0.1, restore: $0.2) }
    }

    static func isRegularFile(_ path: String) -> Bool {
        guard let stat = FileStat.of(path) else { return false }
        return !stat.isDirectory && !stat.isSymlink
    }

    /// True when `directory/CACHEDIR.TAG` is a regular file starting with the Cache Directory Tagging
    /// Specification signature (bford.info/cachedir).
    static func hasCacheDirTag(_ directory: String) -> Bool {
        let tag = directory + "/CACHEDIR.TAG"
        guard isRegularFile(tag), let handle = FileHandle(forReadingAtPath: tag) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: cacheDirTagSignature.count)) ?? Data()
        return Array(head) == cacheDirTagSignature
    }

    struct Entry {
        let name: String
        let isDirectory: Bool
    }

    /// Lists a folder with `readdir`, without following symlinks. Symlinks and other non-folders are
    /// returned with `isDirectory == false`.
    static func entries(of path: String, limit: Int = .max) -> [Entry]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var result: [Entry] = []
        while result.count < limit, let entry = readdir(dir) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(length), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            var isDirectory = Int32(entry.pointee.d_type) == DT_DIR
            if Int32(entry.pointee.d_type) == DT_UNKNOWN {
                let stat = FileStat.of(path + "/" + name)
                isDirectory = stat?.isDirectory == true && stat?.isSymlink == false
            }
            result.append(Entry(name: name, isDirectory: isDirectory))
        }
        return result
    }

    struct Walk {
        let finder: ProjectArtifactFinder
        let device: Int32
        let denyList: DenyList
        let excludes: [String]
        var artifacts: [ProjectArtifact] = []
        var listed = 0
        var activityCache: [String: Date] = [:]

        mutating func run(home: String) {
            // Depth-first, with the enclosing project folders carried along.
            var stack: [(path: String, depth: Int, enclosing: [String])] = [(home, 0, [])]
            while let (path, depth, enclosing) = stack.popLast() {
                if listed >= finder.options.maxDirectories || Task.isCancelled { return }
                listed += 1
                guard let entries = ProjectArtifactFinder.entries(of: path) else { continue }
                let files = Set(entries.filter { !$0.isDirectory }.map(\.name))
                let directories = Set(entries.filter(\.isDirectory).map(\.name))
                let isProject =
                    depth > 0 && !files.union(directories).isDisjoint(with: ProjectArtifactFinder.projectMarkers)
                let found =
                    depth == 0
                    ? [] : ProjectArtifactFinder.classify(directory: path, files: files, directories: directories)
                let artifactNames = Set(found.map(\.name))

                let projectActivity =
                    found.isEmpty && !isProject
                    ? Date.distantPast : activity(of: path, entries: entries, skipping: artifactNames)
                if !found.isEmpty {
                    let enclosingActivity = enclosing.map { activityCache[$0] ?? .distantPast }.max() ?? .distantPast
                    for item in found {
                        let artifactPath = path + "/" + item.name
                        guard let stat = FileStat.of(artifactPath), stat.isDirectory, !stat.isSymlink,
                            stat.device == device
                        else { continue }
                        artifacts.append(
                            ProjectArtifact(
                                path: artifactPath, kind: item.kind, project: path,
                                lastActivity: max(projectActivity, enclosingActivity, stat.modificationDate),
                                restore: item.restore))
                    }
                }

                var childEnclosing = enclosing
                if isProject {
                    activityCache[path] = projectActivity
                    childEnclosing.append(path)
                }
                guard depth < finder.options.maxDepth else { continue }
                for name in directories.sorted().reversed() where shouldDescend(name, depth: depth) {
                    if artifactNames.contains(name) { continue }
                    let child = path + "/" + name
                    guard let stat = FileStat.of(child), stat.isDirectory, !stat.isSymlink, stat.device == device,
                        denyList.denialReason(for: child) == nil,
                        !excludes.contains(where: { pathIsWithin(child, $0, caseInsensitive: true) })
                    else { continue }
                    stack.append((child, depth + 1, childEnclosing))
                }
            }
        }

        func shouldDescend(_ name: String, depth: Int) -> Bool {
            if name.hasPrefix(".") { return false }
            if depth == 0 && ProjectArtifactFinder.skippedHomeFolders.contains(name) { return false }
            if ProjectArtifactFinder.skippedFolders.contains(name) { return false }
            let ext = (name as NSString).pathExtension.lowercased()
            return ext.isEmpty || !ProjectArtifactFinder.skippedExtensions.contains(ext)
        }

        /// Newest modification time of the project folder, its entries, the entries of its (non-hidden,
        /// non-artifact) subfolders, and git's index and HEAD logs. A folder's mtime changes when entries
        /// are added, removed or renamed; editors that save atomically, git, and builds all do that.
        func activity(of project: String, entries: [Entry], skipping artifacts: Set<String>) -> Date {
            var newest = FileStat.of(project)?.modificationDate ?? .distantPast
            func see(_ path: String) {
                if let date = FileStat.of(path)?.modificationDate, date > newest { newest = date }
            }
            for entry in entries where !artifacts.contains(entry.name) && entry.name != "node_modules" {
                let path = project + "/" + entry.name
                see(path)
                guard entry.isDirectory, !entry.name.hasPrefix("."),
                    !ProjectArtifactFinder.skippedFolders.contains(entry.name),
                    let children = ProjectArtifactFinder.entries(of: path, limit: 2_000)
                else { continue }
                for child in children { see(path + "/" + child.name) }
            }
            for gitFile in [".git/index", ".git/HEAD", ".git/FETCH_HEAD", ".git/logs/HEAD"] {
                see(project + "/" + gitFile)
            }
            return newest
        }
    }
}

/// Shares one walk of the home folder between the project probes of a single scan.
public actor ProjectArtifactIndex {
    public static let shared = ProjectArtifactIndex()

    struct Key: Hashable {
        let home: String
        let excludes: [String]
        let now: Date
        let options: ProjectScanOptions
    }

    private var walks: [Key: Task<[ProjectArtifact], Never>] = [:]
    private var order: [Key] = []

    public init() {}

    public func artifacts(for context: ScanContext, options: ProjectScanOptions) async -> [ProjectArtifact] {
        let key = Key(home: context.home, excludes: context.userExcludes, now: context.now, options: options)
        if let walk = walks[key] { return await walk.value }
        let home = context.home
        let denyList = context.denyList
        let excludes = context.userExcludes
        let walk = Task.detached(priority: .utility) {
            ProjectArtifactFinder(options: options).find(home: home, denyList: denyList, excludes: excludes)
        }
        walks[key] = walk
        order.append(key)
        // A scan's probes all ask with the same key at about the same time; older walks are not needed.
        while order.count > 4 { walks[order.removeFirst()] = nil }
        return await walk.value
    }
}

/// Shared logic of the project probes: one walk, filtered by kind and staleness.
enum ProjectArtifactsScan {
    static func findings(
        kinds: Set<ProjectArtifactKind>, context: ScanContext, options: ProjectScanOptions,
        index: ProjectArtifactIndex
    ) async -> [ProbeFinding] {
        let cutoff = context.now.addingTimeInterval(-Double(options.staleAfterDays) * 86_400)
        return await index.artifacts(for: context, options: options)
            .filter { kinds.contains($0.kind) && $0.lastActivity < cutoff }
            .map { artifact in
                let days = max(0, Int(context.now.timeIntervalSince(artifact.lastActivity) / 86_400))
                return ProbeFinding(
                    path: artifact.path,
                    hint:
                        "\(display(artifact.project, home: context.home)), unchanged for \(days) days. \(artifact.restore)"
                )
            }
    }

    static func display(_ path: String, home: String) -> String {
        pathIsWithin(path, home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// `node_modules` folders in projects untouched for a while.
public struct NodeModulesProbe: Probe {
    public static let id = "node.project-modules"
    let options: ProjectScanOptions
    let index: ProjectArtifactIndex

    public init(options: ProjectScanOptions = ProjectScanOptions(), index: ProjectArtifactIndex = .shared) {
        self.options = options
        self.index = index
    }

    public func scan(_ context: ScanContext) async throws -> [ProbeFinding] {
        await ProjectArtifactsScan.findings(kinds: [.nodeModules], context: context, options: options, index: index)
    }
}

/// Python virtual environments in projects untouched for a while.
public struct PythonVirtualEnvProbe: Probe {
    public static let id = "python.project-venvs"
    let options: ProjectScanOptions
    let index: ProjectArtifactIndex

    public init(options: ProjectScanOptions = ProjectScanOptions(), index: ProjectArtifactIndex = .shared) {
        self.options = options
        self.index = index
    }

    public func scan(_ context: ScanContext) async throws -> [ProbeFinding] {
        await ProjectArtifactsScan.findings(
            kinds: [.pythonVirtualEnv], context: context, options: options, index: index)
    }
}

/// Cargo `target` folders in projects untouched for a while.
public struct RustTargetProbe: Probe {
    public static let id = "rust.project-targets"
    let options: ProjectScanOptions
    let index: ProjectArtifactIndex

    public init(options: ProjectScanOptions = ProjectScanOptions(), index: ProjectArtifactIndex = .shared) {
        self.options = options
        self.index = index
    }

    public func scan(_ context: ScanContext) async throws -> [ProbeFinding] {
        await ProjectArtifactsScan.findings(kinds: [.rustTarget], context: context, options: options, index: index)
    }
}

/// Build output and tool caches (SwiftPM, Maven, Gradle, Dart/Flutter, JS frameworks, Python tools)
/// in projects untouched for a while.
public struct ProjectBuildOutputProbe: Probe {
    public static let id = "dev.project-build-outputs"
    let options: ProjectScanOptions
    let index: ProjectArtifactIndex

    public init(options: ProjectScanOptions = ProjectScanOptions(), index: ProjectArtifactIndex = .shared) {
        self.options = options
        self.index = index
    }

    public func scan(_ context: ScanContext) async throws -> [ProbeFinding] {
        await ProjectArtifactsScan.findings(kinds: [.buildOutput], context: context, options: options, index: index)
    }
}
