import Foundation
import Testing

@testable import Updater

struct SemanticVersionTests {
    @Test func parsesPlainAndPrefixed() {
        #expect(SemanticVersion("0.3.0") == SemanticVersion(major: 0, minor: 3, patch: 0))
        #expect(SemanticVersion("v1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(SemanticVersion("V10.20.30")?.core == "10.20.30")
        #expect(SemanticVersion("1.0.0-beta.2")?.prerelease == "beta.2")
    }

    @Test func rejectsMalformed() {
        for text in [
            "", "1", "1.2", "1.2.3.4", "1..3", "a.b.c", " 1.2.3", "1.2.3 ", "1.2.-3", "+1.2.3", "1.2.3-",
            "1.2.3+build", "1.2.3-be/ta", "v", "1.2.3-ünï",
        ] {
            #expect(SemanticVersion(text) == nil, "\(text)")
        }
    }

    @Test func comparesNumerically() throws {
        let v = { (text: String) in SemanticVersion(text)! }
        #expect(v("0.2.0") < v("0.3.0"))
        #expect(v("0.9.0") < v("0.10.0"))
        #expect(v("1.0.0") > v("0.99.99"))
        #expect(v("1.2.3") == v("v1.2.3"))
        #expect(!(v("1.2.3") < v("1.2.3")))
    }

    @Test func prereleaseSortsBelowRelease() {
        let beta = SemanticVersion("1.0.0-beta")!
        #expect(beta < SemanticVersion("1.0.0")!)
        #expect(beta > SemanticVersion("0.9.9")!)
        #expect(SemanticVersion("1.0.0-alpha")! < beta)
        #expect(beta.isPrerelease)
    }

    @Test func coreIsSafeFolderName() {
        #expect(SemanticVersion("v1.2.3-rc.1")!.core == "1.2.3")
        #expect(SemanticVersion("v1.2.3-rc.1")!.description == "1.2.3-rc.1")
    }
}

struct HostPolicyTests {
    let policy = UpdateHostPolicy()

    @Test func allowsGitHubHostsOverHTTPS() {
        for url in [
            "https://api.github.com/repos/leoAnimesh/OpenClean/releases/latest",
            "https://github.com/leoAnimesh/OpenClean/releases/download/v0.3.0/OpenClean-0.3.0.dmg",
            "https://objects.githubusercontent.com/github-production-release-asset/1",
            "https://release-assets.githubusercontent.com/github-production-release-asset/1",
            "https://GitHub.com/x",
        ] {
            #expect(policy.allows(URL(string: url)!), "\(url)")
        }
    }

    @Test func rejectsEverythingElse() {
        for url in [
            "http://github.com/x", "https://evil.com/x", "https://github.com.evil.com/x", "https://evilgithub.com/x",
            "https://user:pw@github.com/x", "https://github.com:8443/x", "ftp://github.com/x",
            "file:///tmp/feed.json", "https://raw.githubusercontent.com/x",
        ] {
            #expect(!policy.allows(URL(string: url)!), "\(url)")
        }
    }

    @Test func fileURLsOnlyWithDevOverride() {
        let file = URL(fileURLWithPath: "/tmp/feed.json")
        #expect(!UpdateHostPolicy().allows(file))
        #expect(UpdateHostPolicy(allowsFileURLs: true).allows(file))
        #expect(!UpdateHostPolicy(allowsFileURLs: true).allows(URL(string: "https://example.com/x")!))
        #expect(throws: UpdateError.self) { try UpdateHostPolicy().check(file) }
    }

    @Test func feedSourceHonoursOverride() {
        let standard = ReleaseFeed.source(environment: [:])
        #expect(standard.url == ReleaseFeed.defaultURL)
        #expect(!standard.policy.allowsFileURLs)

        let path = ReleaseFeed.source(environment: ["OPENCLEAN_UPDATE_FEED": "/tmp/feed.json"])
        #expect(path.url == URL(fileURLWithPath: "/tmp/feed.json"))
        #expect(path.policy.allowsFileURLs)

        let url = ReleaseFeed.source(environment: ["OPENCLEAN_UPDATE_FEED": "file:///tmp/x.json"])
        #expect(url.url.isFileURL)
    }
}
