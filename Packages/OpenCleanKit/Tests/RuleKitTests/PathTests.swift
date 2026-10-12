import Foundation
import Testing
import TestSupport
@testable import RuleKit

struct PathTests {
    @Test func expandsTildeOnlyAtStart() {
        let expander = PathExpander(home: "/Users/tester/")
        #expect(expander.home == "/Users/tester")
        #expect(expander.expand("~") == "/Users/tester")
        #expect(expander.expand("~/Library/Caches/*") == "/Users/tester/Library/Caches/*")
        #expect(expander.expand("/Library/Caches/~x") == "/Library/Caches/~x")
    }

    @Test func fileStatReportsSymlinkWithoutFollowing() throws {
        let dir = try TempDirectory()
        let target = try dir.file("real.bin", bytes: 4096)
        let link = try dir.symlink("link", to: target)
        let linkStat = try #require(FileStat.of(link))
        let fileStat = try #require(FileStat.of(target))
        #expect(linkStat.isSymlink)
        #expect(!fileStat.isSymlink)
        #expect(fileStat.allocatedBytes >= 4096)
        #expect(realPath(link) == target)
        #expect(FileStat.of(dir.path + "/missing") == nil)
    }
}
