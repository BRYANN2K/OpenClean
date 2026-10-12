import Foundation
import RuleKit
import TestSupport
import Testing

@testable import AppInventory

struct LeftoverFinderTests {
    let id = "com.example.foo"

    func relative(_ leftovers: [Leftover], to root: String) -> Set<String> {
        Set(leftovers.map { String($0.path.dropFirst(root.count + 1)) })
    }

    @Test func matchesExactBundleIDEntriesOnly() throws {
        let home = try TempDirectory()
        let system = try TempDirectory()
        let lib = "Library/"
        let expected = [
            "Application Support/com.example.foo/data",
            "Caches/com.example.foo/blob",
            "Logs/com.example.foo/log.txt",
            "Containers/com.example.foo/x",
            "Group Containers/group.com.example.foo/x",
            "Group Containers/ABCDE12345.com.example.foo.shared/x",
            "Saved Application State/com.example.foo.savedState/window",
            "HTTPStorages/com.example.foo/x",
            "WebKit/com.example.foo/x",
            "Application Scripts/com.example.foo/x",
        ]
        for path in expected { try home.file(lib + path, bytes: 512) }
        let expectedFiles = [
            "Preferences/com.example.foo.plist",
            "Preferences/ByHost/com.example.foo.0A1B2C3D-0000-1111-2222-333344445555.plist",
            "HTTPStorages/com.example.foo.binarycookies",
            "LaunchAgents/com.example.foo.plist",
            "LaunchAgents/com.example.foo.updater.plist",
            "Cookies/com.example.foo.binarycookies",
        ]
        for path in expectedFiles { try home.file(lib + path, bytes: 100) }
        // Near misses: prefixes, longer ids, vendor-wide groups, extra components, other apps' agents.
        let misses = [
            "Application Support/com.example.foobar/x",
            "Application Support/com.example/x",
            "Application Support/com.example.foo.extra/x",
            "Application Support/xcom.example.foo/x",
            "Caches/com.example.foo-old/x",
            "Containers/com.example.foo.helper/x",
            "Group Containers/group.com.example/x",
            "Group Containers/ABCDE12345.com.example.foobar/x",
            "Group Containers/ABCDE123.com.example.foo/x",
            "Group Containers/group.com.example.foo.helper/x",
        ]
        for path in misses { try home.file(lib + path) }
        let missFiles = [
            "Preferences/com.example.foo.helper.plist",
            "Preferences/com.example.foobar.plist",
            "Preferences/ByHost/com.example.foo.a.b.plist",
            "Preferences/ByHost/com.example.foobar.0A1B.plist",
            "LaunchAgents/com.example.foo.helper.plist",
            "LaunchAgents/com.example.foo.a.b.plist",
            "LaunchAgents/com.example.foo.plist.bak",
            "Cookies/com.example.foo.cookies",
        ]
        for path in missFiles { try home.file(lib + path) }

        let finder = LeftoverFinder(home: home.path, systemLibrary: system.path + "/Library")
        let found = finder.find(bundleID: id, names: [], otherBundleIDs: ["com.example.foo.helper"])
        let top = Set((expected.map { $0.split(separator: "/").dropLast().joined(separator: "/") } + expectedFiles))
        #expect(relative(found, to: home.path + "/Library") == top)
        #expect(found.allSatisfy { $0.match == .bundleID && $0.scope == .user && $0.isSelectedByDefault })
        #expect(found.first { $0.path.hasSuffix("Caches/com.example.foo") }?.size ?? 0 >= 512)
        #expect(found.first { $0.path.hasSuffix("Caches/com.example.foo") }?.kind == .caches)
        #expect(
            found.first { $0.path.hasSuffix("ByHost/" + expectedFiles[1].split(separator: "/").last!) }?.kind
                == .preferences)
    }

    @Test func matchesBundleIDCaseInsensitively() throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/COM.Example.FOO/x")
        let found = LeftoverFinder(home: home.path, systemLibrary: home.path + "/none").find(bundleID: id, names: [])
        #expect(found.map(\.path) == [home.path + "/Library/Caches/COM.Example.FOO"])
    }

    @Test func matchesExactNameOnlyInSupportCachesAndLogs() throws {
        let home = try TempDirectory()
        try home.file("Library/Application Support/foo/x")
        try home.file("Library/Caches/Foo/x")
        try home.file("Library/Logs/FOO/x")
        try home.file("Library/Containers/Foo/x")
        try home.file("Library/Application Support/Foo Helper/x")
        try home.file("Library/Caches/Foobar/x")
        try home.file("Library/Logs/My Foo/x")
        let found = LeftoverFinder(home: home.path, systemLibrary: home.path + "/none")
            .find(bundleID: id, names: ["Foo", "F"])
        #expect(
            relative(found, to: home.path + "/Library") == ["Application Support/foo", "Caches/Foo", "Logs/FOO"])
        #expect(found.allSatisfy { $0.match == .name && !$0.isSelectedByDefault })
    }

    @Test func respectsDenyList() throws {
        let home = try TempDirectory()
        try home.file("Library/Application Support/OpenClean/settings.json")
        let found = LeftoverFinder(home: home.path, systemLibrary: home.path + "/none")
            .find(bundleID: "com.example.oc", names: ["OpenClean"])
        #expect(found.isEmpty)
    }

    @Test func neverFollowsSymlinks() throws {
        let home = try TempDirectory()
        let outside = try TempDirectory()
        let target = try outside.directory("com.example.foo")
        try outside.file("com.example.foo/precious", bytes: 10)
        // Symlinked entry.
        try home.symlink("Library/Caches/com.example.foo", to: target)
        // Symlinked parent folder.
        try outside.file("webkit/com.example.foo/x")
        try home.directory("Library")
        try home.symlink("Library/WebKit", to: outside.path + "/webkit")
        let found = LeftoverFinder(home: home.path, systemLibrary: home.path + "/none").find(bundleID: id, names: [])
        #expect(found.isEmpty)
    }

    @Test func symlinkedLibraryFindsNothing() throws {
        let home = try TempDirectory()
        let outside = try TempDirectory()
        try outside.file("Library/Caches/com.example.foo/x")
        try home.symlink("Library", to: outside.path + "/Library")
        let found = LeftoverFinder(home: home.path, systemLibrary: home.path + "/none").find(bundleID: id, names: [])
        #expect(found.isEmpty)
    }

    @Test func systemLibraryLeftoversAreReportOnly() throws {
        let home = try TempDirectory()
        let system = try TempDirectory()
        try system.file("Library/LaunchDaemons/com.example.foo.helper.plist")
        try system.file("Library/PrivilegedHelperTools/com.example.foo.helper", bytes: 64)
        try system.file("Library/Application Support/Foo/x")
        try system.file("Library/Caches/Foo/x")
        let found = LeftoverFinder(home: home.path, systemLibrary: system.path + "/Library")
            .find(bundleID: id, names: ["Foo"])
        #expect(
            relative(found, to: system.path + "/Library") == [
                "LaunchDaemons/com.example.foo.helper.plist", "PrivilegedHelperTools/com.example.foo.helper",
                "Application Support/Foo",
            ])
        #expect(found.allSatisfy { $0.scope == .system && $0.isReportOnly && !$0.isSelectedByDefault })
        #expect(found.allSatisfy { $0.scanItem(ruleID: "x").reportOnly })
    }

    @Test func rejectsUnsafeIdentifiers() throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/x")
        let finder = LeftoverFinder(home: home.path, systemLibrary: home.path + "/none")
        #expect(finder.find(bundleID: "..", names: []).isEmpty)
        #expect(finder.find(bundleID: "a/b", names: []).isEmpty)
        #expect(finder.find(bundleID: "", names: [".."]).isEmpty)
        #expect(finder.find(bundleID: "com.example.zzz", names: ["..", "Caches/x"]).isEmpty)
    }
}
