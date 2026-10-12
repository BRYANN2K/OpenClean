import Foundation
import Testing
import TestSupport
@testable import RuleKit

struct GlobMatcherTests {
    @Test func literalPrefixStopsAtFirstWildcard() {
        #expect(GlobMatcher.literalPrefix(of: "/a/b/*/c") == "/a/b")
        #expect(GlobMatcher.literalPrefix(of: "/a/b/c") == "/a/b/c")
        #expect(GlobMatcher.literalPrefix(of: "/a/**/x") == "/a")
        #expect(GlobMatcher.literalPrefix(of: "/*") == "/")
    }

    @Test func starMatchesHiddenAndVisibleChildren() throws {
        let dir = try TempDirectory()
        try dir.file("Caches/a/f", bytes: 1)
        try dir.file("Caches/.hidden/f", bytes: 1)
        try dir.file("Caches/b.txt", bytes: 1)
        let result = GlobMatcher().match(dir.path + "/Caches/*")
        #expect(result.matches == [dir.path + "/Caches/.hidden", dir.path + "/Caches/a", dir.path + "/Caches/b.txt"])
        #expect(result.errors.isEmpty)
    }

    @Test func literalComponentAfterWildcard() throws {
        let dir = try TempDirectory()
        try dir.file("Chrome/Default/Cache/x", bytes: 1)
        try dir.file("Chrome/Profile 1/Cache/x", bytes: 1)
        try dir.file("Chrome/Profile 2/Other/x", bytes: 1)
        let result = GlobMatcher().match(dir.path + "/Chrome/*/Cache")
        #expect(result.matches == [dir.path + "/Chrome/Default/Cache", dir.path + "/Chrome/Profile 1/Cache"])
    }

    @Test func doubleStarMatchesAnyDepth() throws {
        let dir = try TempDirectory()
        try dir.file("p/a/cache2/x", bytes: 1)
        try dir.file("p/b/c/cache2/x", bytes: 1)
        try dir.file("p/cache2/x", bytes: 1)
        let result = GlobMatcher().match(dir.path + "/p/**/cache2")
        #expect(Set(result.matches) == [dir.path + "/p/a/cache2", dir.path + "/p/b/c/cache2", dir.path + "/p/cache2"])
    }

    @Test func noWildcardMatchesOnlyExistingPath() throws {
        let dir = try TempDirectory()
        try dir.directory(".ollama/models")
        #expect(GlobMatcher().match(dir.path + "/.ollama/models").matches == [dir.path + "/.ollama/models"])
        #expect(GlobMatcher().match(dir.path + "/.ollama/nothing").matches.isEmpty)
    }

    @Test func neverTraversesSymlinkedDirectories() throws {
        let dir = try TempDirectory()
        try dir.file("outside/Cache/secret", bytes: 1)
        try dir.directory("Chrome")
        try dir.symlink("Chrome/Linked", to: dir.path + "/outside")
        let result = GlobMatcher().match(dir.path + "/Chrome/*/Cache")
        #expect(result.matches.isEmpty)
    }

    @Test func returnsSymlinkEntriesThemselvesForScannerToFilter() throws {
        let dir = try TempDirectory()
        try dir.directory("Caches")
        try dir.symlink("Caches/evil", to: "/")
        #expect(GlobMatcher().match(dir.path + "/Caches/*").matches == [dir.path + "/Caches/evil"])
    }
}
