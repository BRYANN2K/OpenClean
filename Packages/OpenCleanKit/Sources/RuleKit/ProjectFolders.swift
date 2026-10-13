import Foundation

/// Recognizes regenerable folders inside a project (node_modules, a virtual environment, Cargo's target,
/// ...) from the file next to them that proves which tool made them. Read-only; never follows a symlink.
public enum ProjectArtifactSignature {
    /// JavaScript framework output that sits next to a `package.json`.
    public static let javaScriptOutputs: Set<String> = [
        ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular",
    ]
    /// Python tool caches; recognized only with a valid `CACHEDIR.TAG` inside.
    public static let taggedCaches: Set<String> = [".pytest_cache", ".mypy_cache", ".ruff_cache"]

    static let cacheDirTagSignature = Array("Signature: 8a477f597d28d172789f06886806bc55".utf8)

    /// True when `path` (canonical) is a real folder that one of the project probes would report: its name
    /// and the files in its parent match a known tool, or it holds a `pyvenv.cfg`.
    public static func matches(_ path: String) -> Bool {
        guard let stat = FileStat.of(path), stat.isDirectory, !stat.isSymlink else { return false }
        let bytes = Array(path.utf8)
        guard let slash = bytes.lastIndex(of: 0x2F), slash > 0, slash < bytes.count - 1 else { return false }
        let parent = String(decoding: bytes[..<slash], as: UTF8.self)
        let name = String(decoding: bytes[(slash + 1)...], as: UTF8.self)
        func has(_ file: String) -> Bool { isRegularFile(parent + "/" + file) }
        let gradle = has("build.gradle") || has("build.gradle.kts")

        switch name {
        case "node_modules": if has("package.json") { return true }
        case "target": if has("Cargo.toml") || has("pom.xml") { return true }
        case ".build": if has("Package.swift") { return true }
        case "build": if gradle || has("pubspec.yaml") { return true }
        case ".gradle": if gradle || has("settings.gradle") || has("settings.gradle.kts") { return true }
        case ".dart_tool": if has("pubspec.yaml") { return true }
        default:
            if javaScriptOutputs.contains(name) && has("package.json") { return true }
            if taggedCaches.contains(name) && hasCacheDirTag(path) { return true }
        }
        return isRegularFile(path + "/pyvenv.cfg")
    }

    /// True for a regular file (not a folder, not a symlink).
    public static func isRegularFile(_ path: String) -> Bool {
        guard let stat = FileStat.of(path) else { return false }
        return !stat.isDirectory && !stat.isSymlink
    }

    /// True when `directory/CACHEDIR.TAG` is a regular file starting with the Cache Directory Tagging
    /// Specification signature (bford.info/cachedir).
    public static func hasCacheDirTag(_ directory: String) -> Bool {
        let tag = directory + "/CACHEDIR.TAG"
        guard isRegularFile(tag), let handle = FileHandle(forReadingAtPath: tag) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: cacheDirTagSignature.count)) ?? Data()
        return Array(head) == cacheDirTagSignature
    }
}

/// The one exception to the deny-list's Documents and Desktop rules: regenerable folders that the project
/// probes find inside a folder the user chose under Settings → Project folders.
///
/// `permits` is true only when all of these hold:
/// - the rule uses one of the project probes (`probeIDs`), moves to quarantine and doesn't need admin;
/// - the path is denied for exactly "inside protected location ~/Documents" or "~/Desktop" (every other
///   deny-list reason, including "contains protected location", stays final);
/// - the path is canonical (absolute, no `.`/`..`, no symlink anywhere: `realpath` returns it unchanged),
///   is a real folder, sits strictly inside one of the accepted project folders, and is neither a project
///   folder nor an ancestor of one;
/// - `ProjectArtifactSignature.matches` recognizes it (e.g. `node_modules` next to a `package.json`).
///
/// It is checked at scan time (`ItemBuilder`) and again right before removal (`PreDeleteChecker`), with the
/// project folders as saved at that moment.
public struct ProjectFolderExemption: Sendable, Equatable {
    /// Probes whose findings may use the exemption.
    public static let probeIDs: Set<String> = [
        "node.project-modules", "python.project-venvs", "rust.project-targets", "dev.project-build-outputs",
    ]

    public let home: String
    /// The accepted project folders (canonical); folders that fail `problem(with:home:)` are dropped.
    public let folders: [String]
    let reasons: Set<String>

    public init(home: String, folders: [String]) {
        let denyList = DenyList(home: home)
        self.home = denyList.home
        self.folders = folders.filter { Self.problem(with: $0, home: home) == nil }
        reasons = denyList.documentsAndDesktopReasons
    }

    /// Why `folder` can't be a project folder, or nil if it can. It must be an existing, canonical,
    /// symlink-free folder strictly inside `home`, on the same volume, and either not deny-listed or
    /// deny-listed only for being in Documents or Desktop.
    public static func problem(with folder: String, home rawHome: String) -> String? {
        let home = realPath(rawHome) ?? rawHome
        guard folder.utf8.first == 0x2F, !hasNonCanonicalComponent(folder) else { return "not an absolute path" }
        guard let stat = FileStat.of(folder), stat.isDirectory, !stat.isSymlink else { return "not a folder" }
        guard let real = realPath(folder), Array(real.utf8) == Array(normalizedPath(folder).utf8) else {
            return "goes through a symbolic link"
        }
        guard pathIsWithin(folder, home, caseInsensitive: true), canonicalPathKey(folder) != canonicalPathKey(home)
        else { return "not inside your home folder" }
        guard let homeStat = FileStat.of(home), homeStat.device == stat.device else {
            return "not on the same disk as your home folder"
        }
        let denyList = DenyList(home: home)
        if let reason = denyList.denialReason(for: folder), !denyList.documentsAndDesktopReasons.contains(reason) {
            return "protected (\(reason))"
        }
        return nil
    }

    public func permits(_ path: String, deniedFor reason: String, rule: Rule) -> Bool {
        guard let probe = rule.probe, Self.probeIDs.contains(probe), rule.effectiveDeleteMode == .quarantine,
            !rule.needs(.admin), reasons.contains(reason)
        else { return false }
        guard path.utf8.first == 0x2F, !hasNonCanonicalComponent(path),
            let real = realPath(path), Array(real.utf8) == Array(path.utf8)
        else { return false }
        let key = canonicalPathKey(path)
        let folderKeys = folders.map(canonicalPathKey)
        // Never a project folder itself, nor anything that contains one.
        if folderKeys.contains(where: { isAncestorOrEqual(key, of: $0) }) { return false }
        guard folderKeys.contains(where: { isAncestorOrEqual($0, of: key) }) else { return false }
        return ProjectArtifactSignature.matches(path)
    }
}
