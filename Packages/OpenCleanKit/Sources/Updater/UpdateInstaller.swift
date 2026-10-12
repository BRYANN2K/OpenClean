import Foundation
import ProcessKit
import RuleKit

/// A validated copy of the new OpenClean.app, ready to be swapped in by `SelfUpdateReplacer`.
public struct StagedUpdate: Sendable, Equatable {
    public let release: Release
    /// `<updates>/<X.Y.Z>/staged-<id>/OpenClean.app`
    public let appPath: String
    /// The verified disk image it came from (offered as "Open Installer" when an in-place install isn't possible).
    public let dmgPath: String

    public init(release: Release, appPath: String, dmgPath: String) {
        self.release = release
        self.appPath = appPath
        self.dmgPath = dmgPath
    }

    public var version: SemanticVersion { release.version }
}

/// Copies OpenClean.app out of a verified disk image and checks it, without touching the installed app.
///
/// 1. `hdiutil attach -nobrowse -readonly -noautoopen -plist <dmg>` (read-only, not shown in Finder).
/// 2. `ditto` the app into a fresh `staged-<id>` folder next to the image, then detach.
/// 3. The copy must be a real directory (not a symlink), its `CFBundleIdentifier` must equal the running
///    app's, its `CFBundleShortVersionString` must equal the release version, and
///    `codesign --verify --deep --strict` must pass.
///
/// Never deletes: a failed staging folder stays inside `<updates>/<X.Y.Z>/` until `UpdateStagingCleaner`
/// clears it.
public struct UpdateInstaller: Sendable {
    public static let appName = "OpenClean.app"

    let runner: any CommandRunner
    let bundleIdentifier: String

    public init(runner: any CommandRunner = ProcessCommandRunner(timeout: 180), bundleIdentifier: String) {
        self.runner = runner
        self.bundleIdentifier = bundleIdentifier
    }

    public func stage(_ download: VerifiedDownload) throws -> StagedUpdate {
        let dmg = download.dmgPath
        guard FileStat.of(dmg).map({ !$0.isDirectory && !$0.isSymlink }) == true else {
            throw UpdateError.stagingFailed("the disk image is missing")
        }
        let attach = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", dmg])
        guard attach.status == 0 else {
            throw UpdateError.stagingFailed("hdiutil attach failed: \(attach.stderrText.trimmed)")
        }
        guard let mountPoint = Self.mountPoint(fromAttachPlist: attach.stdout) else {
            throw UpdateError.stagingFailed("the disk image has no mountable volume")
        }
        let staged: String
        do {
            // Detach as soon as the copy is done (or failed), before validating the copy.
            defer { detach(mountPoint) }
            let source = (mountPoint as NSString).appendingPathComponent(Self.appName)
            guard let stat = FileStat.of(source), stat.isDirectory, !stat.isSymlink else {
                throw UpdateError.invalidBundle("\(Self.appName) is not on the disk image")
            }
            let stagingFolder = ((dmg as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("staged-" + UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(atPath: stagingFolder, withIntermediateDirectories: false)
            staged = (stagingFolder as NSString).appendingPathComponent(Self.appName)
            let copy = try run("/usr/bin/ditto", [source, staged])
            guard copy.status == 0 else {
                throw UpdateError.stagingFailed("ditto failed: \(copy.stderrText.trimmed)")
            }
        }

        try Self.validate(
            app: staged, bundleIdentifier: bundleIdentifier, version: download.release.version, runner: runner)
        return StagedUpdate(release: download.release, appPath: staged, dmgPath: dmg)
    }

    /// Bundle id, version and code signature of a staged app.
    public static func validate(
        app: String, bundleIdentifier: String, version: SemanticVersion, runner: any CommandRunner
    ) throws {
        guard let stat = FileStat.of(app), stat.isDirectory, !stat.isSymlink else {
            throw UpdateError.invalidBundle("not an app bundle")
        }
        guard let info = bundleInfo(app) else { throw UpdateError.invalidBundle("Info.plist is unreadable") }
        guard info.identifier == bundleIdentifier else {
            throw UpdateError.invalidBundle("bundle identifier is \(info.identifier ?? "missing")")
        }
        guard let stagedVersion = info.version.flatMap(SemanticVersion.init), stagedVersion == version else {
            throw UpdateError.invalidBundle("it reports version \(info.version ?? "none"), expected \(version)")
        }
        let output: CommandOutput
        do {
            output = try runner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app])
        } catch {
            throw UpdateError.signatureInvalid("\(error)")
        }
        guard output.status == 0 else { throw UpdateError.signatureInvalid(output.stderrText.trimmed) }
    }

    /// `CFBundleIdentifier` and `CFBundleShortVersionString` from `<app>/Contents/Info.plist`.
    public static func bundleInfo(_ app: String) -> (identifier: String?, version: String?)? {
        let plist = URL(fileURLWithPath: app).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return (dictionary["CFBundleIdentifier"] as? String, dictionary["CFBundleShortVersionString"] as? String)
    }

    /// The first `mount-point` in `hdiutil attach -plist` output; must be an absolute canonical path.
    static func mountPoint(fromAttachPlist data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]]
        else { return nil }
        for entity in entities {
            if let mount = entity["mount-point"] as? String, mount.utf8.first == 0x2F, !hasNonCanonicalComponent(mount)
            {
                return mount
            }
        }
        return nil
    }

    private func detach(_ mountPoint: String) {
        if let result = try? run("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"]), result.status == 0 { return }
        _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint, "-force", "-quiet"])
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        do {
            return try runner.run(executable, arguments)
        } catch {
            throw UpdateError.stagingFailed("\((executable as NSString).lastPathComponent): \(error)")
        }
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
