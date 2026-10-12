import Foundation
import TestSupport
import Testing

@testable import Updater

struct ReleaseFeedTests {
    static let dmgURL = "https://github.com/leoAnimesh/OpenClean/releases/download/v0.3.0/OpenClean-0.3.0.dmg"
    static let sumsURL = "https://github.com/leoAnimesh/OpenClean/releases/download/v0.3.0/SHA256SUMS.txt"

    func feed(_ client: FakeHTTPClient) -> ReleaseFeed {
        ReleaseFeed(client: client, appVersion: "0.2.0")
    }

    @Test func parsesLatestRelease() async throws {
        let client = FakeHTTPClient()
        client.respond(
            ReleaseFeed.defaultURL,
            body: releaseJSON(
                tag: "v0.3.0",
                assets: [
                    ("OpenClean-0.3.0.dmg", Self.dmgURL, 1234), ("SHA256SUMS.txt", Self.sumsURL, 200),
                    ("openclean-cli-0.3.0.zip", "https://github.com/x.zip", 99),
                ]))
        let release = try await feed(client).latest()
        #expect(release.version == SemanticVersion("0.3.0"))
        #expect(release.tagName == "v0.3.0")
        #expect(release.notes.contains("Something new"))
        #expect(release.htmlURL.absoluteString == "https://github.com/leoAnimesh/OpenClean/releases/tag/v0.3.0")
        #expect(release.publishedAt != nil)
        #expect(release.dmg?.size == 1234)
        #expect(release.dmg?.downloadURL.absoluteString == Self.dmgURL)
        #expect(release.checksums?.name == "SHA256SUMS.txt")
        #expect(release.isInstallable)
    }

    @Test func sendsOnlyTheDocumentedHeaders() async throws {
        let client = FakeHTTPClient()
        client.respond(ReleaseFeed.defaultURL, body: releaseJSON(tag: "v0.3.0", assets: []))
        _ = try await feed(client).latest()
        let request = try #require(client.requests.first)
        #expect(request.url == ReleaseFeed.defaultURL)
        #expect(request.httpMethod == "GET")
        #expect(
            request.allHTTPHeaderFields == [
                "Accept": "application/vnd.github+json", "User-Agent": "OpenClean/0.2.0", "Accept-Language": "en",
            ])
    }

    @Test func releaseWithoutDiskImageOrChecksumsIsNotInstallable() async throws {
        let client = FakeHTTPClient()
        client.respond(
            ReleaseFeed.defaultURL, body: releaseJSON(tag: "v0.3.0", assets: [("OpenClean-0.3.0.dmg", Self.dmgURL, 1)]))
        #expect(try await feed(client).latest().isInstallable == false)

        client.respond(
            ReleaseFeed.defaultURL, body: releaseJSON(tag: "v0.3.0", assets: [("SHA256SUMS.txt", Self.sumsURL, 1)]))
        #expect(try await feed(client).latest().isInstallable == false)

        // A DMG for another version doesn't count.
        client.respond(
            ReleaseFeed.defaultURL,
            body: releaseJSON(
                tag: "v0.3.0", assets: [("OpenClean-0.2.0.dmg", Self.dmgURL, 1), ("SHA256SUMS.txt", Self.sumsURL, 1)]))
        #expect(try await feed(client).latest().isInstallable == false)
    }

    @Test func prereleaseIsNeverInstallable() async throws {
        let client = FakeHTTPClient()
        client.respond(
            ReleaseFeed.defaultURL,
            body: releaseJSON(
                tag: "v0.3.0", assets: [("OpenClean-0.3.0.dmg", Self.dmgURL, 1), ("SHA256SUMS.txt", Self.sumsURL, 1)],
                prerelease: true))
        let release = try await feed(client).latest()
        #expect(release.version.isPrerelease)
        #expect(!release.isInstallable)
    }

    @Test func mapsHTTPErrors() async {
        let client = FakeHTTPClient()
        await #expect(throws: UpdateError.noPublishedRelease) { try await feed(client).latest() }
        client.respond(ReleaseFeed.defaultURL, status: 403, text: "rate limited")
        await #expect(throws: UpdateError.rateLimited) { try await feed(client).latest() }
        client.respond(ReleaseFeed.defaultURL, status: 500, text: "")
        await #expect(throws: UpdateError.httpStatus(500)) { try await feed(client).latest() }
        client.respond(ReleaseFeed.defaultURL, text: "not json")
        await #expect(throws: UpdateError.self) { try await feed(client).latest() }
        client.respond(ReleaseFeed.defaultURL, body: releaseJSON(tag: "latest", assets: []))
        await #expect(throws: UpdateError.self) { try await feed(client).latest() }
    }

    @Test func refusesFeedOutsideAllowlist() async {
        let client = FakeHTTPClient()
        let url = URL(string: "https://example.com/feed.json")!
        client.respond(url, body: releaseJSON(tag: "v9.9.9", assets: []))
        let feed = ReleaseFeed(client: client, appVersion: "0.2.0", url: url)
        await #expect(throws: UpdateError.hostNotAllowed("example.com")) { try await feed.latest() }
        #expect(client.requests.isEmpty)
    }

    @Test func untrustedReleasePageFallsBackToReleasesList() throws {
        var object =
            try JSONSerialization.jsonObject(with: releaseJSON(tag: "v0.3.0", assets: [])) as! [String: Any]
        object["html_url"] = "https://evil.example/phish"
        let release = try ReleaseFeed.parse(JSONSerialization.data(withJSONObject: object), policy: UpdateHostPolicy())
        #expect(release.htmlURL == ReleaseFeed.releasesPage)
    }

    @Test func readsFileFeedThroughRealClientWhenOverridden() async throws {
        let temp = try TempDirectory()
        let path = try temp.file("feed.json")
        try releaseJSON(tag: "v9.9.9", assets: []).write(to: URL(fileURLWithPath: path))
        let source = ReleaseFeed.source(environment: ["OPENCLEAN_UPDATE_FEED": path])
        let feed = ReleaseFeed(
            client: URLSessionHTTPClient(policy: source.policy), appVersion: "0.2.0", url: source.url,
            policy: source.policy)
        #expect(try await feed.latest().version == SemanticVersion("9.9.9"))

        // Without the override the real client refuses file:// before reading anything.
        let strict = URLSessionHTTPClient(policy: UpdateHostPolicy())
        await #expect(throws: UpdateError.self) {
            _ = try await strict.data(for: URLRequest(url: URL(fileURLWithPath: path)))
        }
    }
}

struct ReleaseNotesTests {
    @Test func splitsHeadingsBulletsAndParagraphs() {
        let blocks = ReleaseNotes.blocks(
            from:
                "## Features\n- **app:** in-app updates (abc123)\n- faster scans\n\nPlain text\ncontinues\n### Fixes\n* fixed"
        )
        #expect(blocks.count == 6)
        guard case .heading(let heading, _) = blocks[0] else {
            Issue.record("not a heading")
            return
        }
        #expect(String(heading.characters) == "Features")
        guard case .bullet(let bullet, _) = blocks[1] else {
            Issue.record("not a bullet")
            return
        }
        #expect(String(bullet.characters) == "app: in-app updates (abc123)")
        guard case .paragraph(let paragraph, _) = blocks[3] else {
            Issue.record("not a paragraph")
            return
        }
        #expect(String(paragraph.characters) == "Plain text continues")
        #expect(Set(blocks.map(\.id)).count == blocks.count)
    }

    @Test func emptyNotesHaveNoBlocks() {
        #expect(ReleaseNotes.blocks(from: "").isEmpty)
        #expect(ReleaseNotes.blocks(from: "\n\n").isEmpty)
    }
}
