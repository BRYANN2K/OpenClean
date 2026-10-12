import Foundation
import RuleKit

/// Clears downloaded disk images and staging folders from `<support>/Updates/`. Lives in Quarantine
/// because only Quarantine and Privilege may remove files; the Updater module itself never deletes.
///
/// Only direct children of the (resolved) Updates folder are removed, named by a single plain path
/// component, and never through a symlink: a symlinked child is removed as a link, its target is untouched.
public struct UpdateStagingCleaner: Sendable {
    let updatesDirectory: URL

    public init(updatesDirectory: URL) {
        self.updatesDirectory = updatesDirectory
    }

    /// Removes `<updates>/<name>` if it exists. Throws for names that aren't one plain component.
    public func remove(_ name: String) throws {
        guard Self.isPlainComponent(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        guard let root = resolvedRoot() else { return }
        let target = (root as NSString).appendingPathComponent(name)
        guard FileStat.of(target) != nil else { return }
        // Contained exactly one level below the resolved root, compared on canonical keys.
        guard canonicalPathKey((target as NSString).deletingLastPathComponent) == canonicalPathKey(root),
            canonicalPathKey(target) != canonicalPathKey(root)
        else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(atPath: target)
    }

    /// Removes every child of the Updates folder except `keeping`. Returns the names removed.
    @discardableResult
    public func removeAll(keeping: String? = nil) -> [String] {
        guard let root = resolvedRoot(),
            let names = try? FileManager.default.contentsOfDirectory(atPath: root)
        else { return [] }
        var removed: [String] = []
        for name in names where name != keeping {
            if (try? remove(name)) != nil { removed.append(name) }
        }
        return removed
    }

    /// The Updates folder with symlinks resolved, or nil if it doesn't exist or is itself a symlink.
    func resolvedRoot() -> String? {
        let path = updatesDirectory.path
        guard let stat = FileStat.of(path), stat.isDirectory, !stat.isSymlink else { return nil }
        return realPath(path)
    }

    static func isPlainComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.utf8.contains(0x2F) && !name.utf8.contains(0)
    }
}
