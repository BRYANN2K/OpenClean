import CryptoKit
import Foundation
import TestSupport
import Testing

@testable import Updater

func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// A release for `version` whose assets live at fake GitHub URLs, with the fake client primed.
func primedRelease(
    _ client: FakeHTTPClient, version: String = "0.3.0", dmg: Data = Data(repeating: 0x42, count: 4096),
    checksum: String? = nil, listedSize: Int? = nil, dmgHost: String = "github.com"
) -> Release {
    let dmgName = "OpenClean-\(version).dmg"
    let dmgURL = URL(string: "https://\(dmgHost)/leoAnimesh/OpenClean/releases/download/v\(version)/\(dmgName)")!
    let sumsURL = URL(string: "https://github.com/leoAnimesh/OpenClean/releases/download/v\(version)/SHA256SUMS.txt")!
    client.respond(dmgURL, body: dmg)
    client.respond(
        sumsURL,
        text:
            "\(String(repeating: "a", count: 64))  openclean-cli-\(version).zip\n\(checksum ?? sha256Hex(dmg))  \(dmgName)\n"
    )
    return Release(
        version: SemanticVersion(version)!, tagName: "v\(version)", name: "OpenClean \(version)", notes: "",
        htmlURL: ReleaseFeed.releasesPage, publishedAt: nil,
        assets: [
            ReleaseAsset(name: dmgName, downloadURL: dmgURL, size: Int64(listedSize ?? dmg.count)),
            ReleaseAsset(name: "SHA256SUMS.txt", downloadURL: sumsURL, size: 200),
        ])
}

struct DownloaderTests {
    func downloader(_ client: FakeHTTPClient, _ temp: TempDirectory) -> UpdateDownloader {
        UpdateDownloader(
            client: client, policy: UpdateHostPolicy(), updatesDirectory: temp.url.appendingPathComponent("Updates"),
            appVersion: "0.2.0")
    }

    @Test func downloadsAndVerifies() async throws {
        let temp = try TempDirectory()
        let client = FakeHTTPClient()
        let release = primedRelease(client)
        let (stream, continuation) = AsyncStream.makeStream(of: DownloadProgress.self)
        let result = try await downloader(client, temp).download(release, progress: continuation)
        var updates: [DownloadProgress] = []
        for await update in stream { updates.append(update) }

        #expect(result.dmgPath == temp.path + "/Updates/0.3.0/OpenClean-0.3.0.dmg")
        #expect(FileManager.default.fileExists(atPath: result.dmgPath))
        #expect(result.sha256 == sha256Hex(Data(repeating: 0x42, count: 4096)))
        #expect(updates.last?.received == 4096)
        #expect(updates.last?.total == 4096)
        #expect(updates.last?.fraction == 1)
        // Every request identifies only as OpenClean/<version>.
        #expect(client.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "OpenClean/0.2.0" })
    }

    @Test func checksumMismatchIsAnError() async throws {
        let temp = try TempDirectory()
        let client = FakeHTTPClient()
        let release = primedRelease(client, checksum: String(repeating: "0", count: 64))
        await #expect(throws: UpdateError.checksumMismatch("OpenClean-0.3.0.dmg")) {
            try await downloader(client, temp).download(release)
        }
    }

    @Test func missingChecksumLineIsAnError() async throws {
        let temp = try TempDirectory()
        let client = FakeHTTPClient()
        let release = primedRelease(client)
        client.respond(release.checksums!.downloadURL, text: "\(String(repeating: "b", count: 64))  other.dmg\n")
        await #expect(throws: UpdateError.missingChecksum("OpenClean-0.3.0.dmg")) {
            try await downloader(client, temp).download(release)
        }
        // The disk image was never requested.
        #expect(!client.requests.contains { $0.url == release.dmg?.downloadURL })
    }

    @Test func sizeMismatchIsAnError() async throws {
        let temp = try TempDirectory()
        let client = FakeHTTPClient()
        let release = primedRelease(client, listedSize: 10)
        await #expect(throws: UpdateError.sizeMismatch(expected: 10, actual: 4096)) {
            try await downloader(client, temp).download(release)
        }
    }

    @Test func refusesAssetsOutsideAllowlist() async throws {
        let temp = try TempDirectory()
        let client = FakeHTTPClient()
        let release = primedRelease(client, dmgHost: "downloads.example.com")
        await #expect(throws: UpdateError.hostNotAllowed("downloads.example.com")) {
            try await downloader(client, temp).download(release)
        }
        #expect(client.requests.isEmpty)
    }

    @Test func refusesToOverwriteEarlierDownload() async throws {
        let temp = try TempDirectory()
        let client = FakeHTTPClient()
        let release = primedRelease(client)
        try temp.file("Updates/0.3.0/OpenClean-0.3.0.dmg", bytes: 3)
        await #expect(throws: UpdateError.self) { try await downloader(client, temp).download(release) }
    }

    @Test func notInstallableReleaseIsRefused() async throws {
        let temp = try TempDirectory()
        let release = Release(
            version: SemanticVersion("0.3.0")!, tagName: "v0.3.0", name: "", notes: "",
            htmlURL: ReleaseFeed.releasesPage, publishedAt: nil, assets: [])
        await #expect(throws: UpdateError.notInstallable) {
            try await downloader(FakeHTTPClient(), temp).download(release)
        }
    }

    @Test func cancellationStopsTheDownload() async throws {
        let temp = try TempDirectory()
        let client = FakeHTTPClient()
        let release = primedRelease(client)
        client.respond(release.dmg!.downloadURL, body: Data(repeating: 1, count: 10), delay: .seconds(30))
        let downloader = downloader(client, temp)
        let task = Task { try await downloader.download(release) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func parsesShasumOutput() {
        let digest = String(repeating: "c", count: 64)
        #expect(UpdateDownloader.checksum(for: "a.dmg", in: "\(digest)  a.dmg") == digest)
        #expect(UpdateDownloader.checksum(for: "a.dmg", in: "\(digest.uppercased()) *a.dmg\r\n") == digest)
        #expect(UpdateDownloader.checksum(for: "a.dmg", in: "\(digest)  b.dmg") == nil)
        #expect(UpdateDownloader.checksum(for: "a.dmg", in: "abc  a.dmg") == nil)
        #expect(UpdateDownloader.checksum(for: "a.dmg", in: "\(digest)  a.dmg.sig") == nil)
    }

    @Test func fileCopyReportsProgress() throws {
        let temp = try TempDirectory()
        let source = try temp.file("in.bin", bytes: 3 << 20)
        let counter = Counter()
        try URLSessionHTTPClient.copyFile(
            from: URL(fileURLWithPath: source), to: temp.url.appendingPathComponent("out.bin")
        ) { received, total in
            counter.record(received, total)
        }
        #expect(counter.last == 3 << 20)
        #expect(counter.calls == 3)
        #expect(try UpdateDownloader.sha256(of: source) == UpdateDownloader.sha256(of: temp.path + "/out.bin"))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func record(_ received: Int64, _ total: Int64?) { lock.withLock { values.append(received) } }
    var last: Int64? { lock.withLock { values.last } }
    var calls: Int { lock.withLock { values.count } }
}
