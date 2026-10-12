import Foundation
import RuleKit
import ScanEngine

/// Finds files an app left in `~/Library` (removable) and `/Library` (report-only).
///
/// Matching is exact: an entry is named after the bundle id (optionally with a fixed extension, or one
/// extra dot-free component such as a ByHost UUID), or, in a few folders, exactly after the app's name.
/// There is no substring or fuzzy matching. Symlinks are never followed.
public struct LeftoverFinder: Sendable {
    /// Resolved home; the user Library is `<home>/Library`.
    public let home: String
    public let systemLibrary: String
    let denyList: DenyList

    public init(home: String, systemLibrary: String = "/Library") {
        let resolved = realPath(home) ?? home
        self.home = resolved
        self.systemLibrary = systemLibrary
        denyList = DenyList(home: resolved)
    }

    enum Pattern {
        /// `<id>` exactly.
        case id
        /// `<id><suffix>`, e.g. `.plist`.
        case idSuffix(String)
        /// `<id>.<one dot-free component><suffix>`, e.g. ByHost `<id>.<UUID>.plist`; also `<id><suffix>`.
        case idDotted(String)
        /// A group container named `<id>…` after a `group.` or team-id prefix.
        case groupContainer
        /// The app's name exactly (case-insensitive).
        case name
    }

    struct Location {
        let folder: String
        let kind: LeftoverKind
        let patterns: [Pattern]
    }

    static let userLocations: [Location] = [
        Location(folder: "Application Support", kind: .applicationSupport, patterns: [.id, .name]),
        Location(folder: "Caches", kind: .caches, patterns: [.id, .name]),
        Location(folder: "Logs", kind: .logs, patterns: [.id, .name]),
        Location(folder: "Preferences", kind: .preferences, patterns: [.idSuffix(".plist")]),
        Location(folder: "Preferences/ByHost", kind: .preferences, patterns: [.idDotted(".plist")]),
        Location(folder: "Containers", kind: .containers, patterns: [.id]),
        Location(folder: "Group Containers", kind: .groupContainers, patterns: [.groupContainer]),
        Location(folder: "Saved Application State", kind: .savedState, patterns: [.idSuffix(".savedState")]),
        Location(folder: "HTTPStorages", kind: .httpStorages, patterns: [.id, .idSuffix(".binarycookies")]),
        Location(folder: "WebKit", kind: .webKit, patterns: [.id]),
        Location(folder: "Application Scripts", kind: .applicationScripts, patterns: [.id]),
        Location(folder: "LaunchAgents", kind: .launchAgents, patterns: [.idDotted(".plist")]),
        Location(folder: "Cookies", kind: .cookies, patterns: [.idSuffix(".binarycookies")]),
    ]

    static let systemLocations: [Location] = [
        Location(folder: "Application Support", kind: .applicationSupport, patterns: [.id, .name]),
        Location(folder: "Caches", kind: .caches, patterns: [.id]),
        Location(folder: "Logs", kind: .logs, patterns: [.id, .name]),
        Location(folder: "Preferences", kind: .preferences, patterns: [.idSuffix(".plist")]),
        Location(folder: "LaunchAgents", kind: .launchAgents, patterns: [.idDotted(".plist")]),
        Location(folder: "LaunchDaemons", kind: .launchDaemons, patterns: [.idDotted(".plist")]),
        Location(folder: "PrivilegedHelperTools", kind: .privilegedHelpers, patterns: [.id, .idDotted("")]),
    ]

    /// Leftovers for one app. `otherBundleIDs` are the ids of other installed apps: an entry that is really
    /// named after one of them (e.g. `com.foo.helper.plist` when `com.foo.helper` is installed) is left out.
    public func find(bundleID: String, names: [String], otherBundleIDs: Set<String> = []) -> [Leftover] {
        guard isSafeComponent(bundleID) else { return [] }
        let matcher = Matcher(
            bundleID: bundleID,
            names: names.filter { isSafeComponent($0) && $0.count >= 3 },
            others: otherBundleIDs.filter { canonicalNameKey($0) != canonicalNameKey(bundleID) })
        var found: [Leftover] = []
        var seen = Set<[UInt8]>()
        let roots: [(String, LeftoverScope, [Location])] = [
            (home + "/Library", .user, Self.userLocations),
            (systemLibrary, .system, Self.systemLocations),
        ]
        for (root, scope, locations) in roots {
            // Fail closed if the Library itself is reached through a symlink.
            guard realPath(root) == root else { continue }
            for location in locations {
                let folder = root + "/" + location.folder
                guard realPath(folder) == folder, FileStat.of(folder)?.isDirectory == true,
                    let entries = try? FileManager.default.contentsOfDirectory(atPath: folder)
                else { continue }
                for entry in entries.sorted() where isSafeComponent(entry) {
                    guard let match = matcher.match(entry, location.patterns) else { continue }
                    let path = folder + "/" + entry
                    guard seen.insert(canonicalPathKey(path)).inserted,
                        let leftover = admit(path, folder: folder, root: root, kind: location.kind, match, scope)
                    else { continue }
                    found.append(leftover)
                }
            }
        }
        return found
    }

    private func admit(
        _ path: String, folder: String, root: String, kind: LeftoverKind, _ match: LeftoverMatch,
        _ scope: LeftoverScope
    ) -> Leftover? {
        guard let stat = FileStat.of(path), !stat.isSymlink,
            !hasNonCanonicalComponent(path),
            pathIsWithin(path, root, caseInsensitive: true), pathIsWithin(path, folder, caseInsensitive: true),
            canonicalPathKey(path) != canonicalPathKey(folder),
            denyList.denialReason(for: path) == nil
        else { return nil }
        return Leftover(
            path: path, kind: kind, match: match, scope: scope,
            size: FileSizer.allocatedSize(of: path, ledger: HardLinkLedger()), device: stat.device,
            inode: stat.inode, modificationDate: stat.modificationDate, ownerUID: stat.ownerUID,
            isDirectory: stat.isDirectory)
    }

    /// Byte-level, case-insensitive name matching.
    struct Matcher {
        let id: [UInt8]
        let names: [[UInt8]]
        let others: [[UInt8]]

        init(bundleID: String, names: [String], others: Set<String>) {
            id = canonicalNameKey(bundleID)
            self.names = names.map(canonicalNameKey)
            self.others = others.map(canonicalNameKey)
        }

        func match(_ entry: String, _ patterns: [Pattern]) -> LeftoverMatch? {
            let key = canonicalNameKey(entry)
            for pattern in patterns {
                switch pattern {
                case .id:
                    if key == id { return .bundleID }
                case .idSuffix(let suffix):
                    if key == id + canonicalNameKey(suffix) { return .bundleID }
                case .idDotted(let suffix):
                    if dotted(key, suffix: canonicalNameKey(suffix)) { return .bundleID }
                case .groupContainer:
                    if groupContainer(key) { return .bundleID }
                case .name:
                    if names.contains(key) { return .name }
                }
            }
            return nil
        }

        /// `<id><suffix>` or `<id>.<X><suffix>` with X non-empty and dot-free, unless `<id>.<X>` is another app's id.
        func dotted(_ key: [UInt8], suffix: [UInt8]) -> Bool {
            if !suffix.isEmpty, key == id + suffix { return true }
            let head = id + [0x2E]
            guard key.count > head.count + suffix.count, key.starts(with: head), key.suffix(suffix.count) == suffix[...]
            else { return false }
            let middle = key[head.count..<(key.count - suffix.count)]
            guard !middle.isEmpty, !middle.contains(0x2E) else { return false }
            return !belongsToOther(Array(key.prefix(key.count - suffix.count)))
        }

        /// `group.<id>[.more]` or `<TEAMID>.<id>[.more]` (team id: 10 letters/digits).
        func groupContainer(_ key: [UInt8]) -> Bool {
            let group = Array("group.".utf8)
            var rest: ArraySlice<UInt8>
            if key.starts(with: group) {
                rest = key.dropFirst(group.count)
            } else if key.count > 11, key[10] == 0x2E, key.prefix(10).allSatisfy(Self.isAlphanumeric) {
                rest = key.dropFirst(11)
            } else {
                return false
            }
            if rest.elementsEqual(id) { return true }
            guard rest.starts(with: id + [0x2E]), rest.count > id.count + 1 else { return false }
            return !belongsToOther(Array(rest))
        }

        /// True when `stem` is another installed app's id, or lies under one more specific than ours.
        func belongsToOther(_ stem: [UInt8]) -> Bool {
            others.contains { other in
                other.count > id.count && (stem == other || (stem.starts(with: other + [0x2E])))
            }
        }

        static func isAlphanumeric(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte) || (0x61...0x7A).contains(byte) || (0x41...0x5A).contains(byte)
        }
    }
}
