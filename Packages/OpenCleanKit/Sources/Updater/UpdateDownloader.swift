import CryptoKit
import Foundation

public struct DownloadProgress: Sendable, Equatable {
    public let received: Int64
    /// Nil when neither the server nor the release says how big the file is.
    public let total: Int64?
    public let bytesPerSecond: Double

    public init(received: Int64, total: Int64?, bytesPerSecond: Double) {
        self.received = received
        self.total = total
        self.bytesPerSecond = bytesPerSecond
    }

    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }
}

/// A disk image whose SHA-256 matched the release's `SHA256SUMS.txt`.
public struct VerifiedDownload: Sendable, Equatable {
    public let release: Release
    public let dmgPath: String
    public let sha256: String

    public init(release: Release, dmgPath: String, sha256: String) {
        self.release = release
        self.dmgPath = dmgPath
        self.sha256 = sha256
    }
}

/// Downloads a release's disk image into `<updates>/<X.Y.Z>/` and checks it against the release's
/// `SHA256SUMS.txt`. The checksum file comes from the same release, so this proves the image arrived
/// intact; it does not prove who published it. Never deletes anything: a stale folder must be cleared
/// by `UpdateStagingCleaner` (Quarantine) before calling `download`.
public struct UpdateDownloader: Sendable {
    static let maximumChecksumBytes = 64 << 10

    let client: any HTTPClient
    let policy: UpdateHostPolicy
    let updatesDirectory: URL
    let appVersion: String

    public init(client: any HTTPClient, policy: UpdateHostPolicy, updatesDirectory: URL, appVersion: String) {
        self.client = client
        self.policy = policy
        self.updatesDirectory = updatesDirectory
        self.appVersion = appVersion
    }

    public func versionDirectory(for version: SemanticVersion) -> URL {
        updatesDirectory.appendingPathComponent(version.core, isDirectory: true)
    }

    /// Downloads and verifies. Progress updates go to `progress` (finished when this returns or throws).
    /// Cancelling the calling task stops the download and throws `CancellationError`.
    public func download(_ release: Release, progress: AsyncStream<DownloadProgress>.Continuation? = nil)
        async throws -> VerifiedDownload
    {
        defer { progress?.finish() }
        guard release.isInstallable, let dmg = release.dmg, let sums = release.checksums else {
            throw UpdateError.notInstallable
        }
        try policy.check(dmg.downloadURL)
        try policy.check(sums.downloadURL)

        let directory = versionDirectory(for: release.version)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(release.dmgName)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw UpdateError.downloadFailed("an earlier download is still in the way")
        }

        let expected = try await expectedChecksum(for: release.dmgName, from: sums)
        try Task.checkCancellation()

        let meter = RateMeter(total: dmg.size > 0 ? dmg.size : nil, continuation: progress)
        let response = try await client.download(
            ReleaseFeed.request(dmg.downloadURL, appVersion: appVersion, accept: "application/octet-stream"),
            to: destination
        ) { received, total in
            meter.update(received: received, total: total)
        }
        guard (200..<300).contains(response.status) else { throw UpdateError.httpStatus(response.status) }
        meter.finish()

        let actualSize =
            (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
            ?? -1
        if dmg.size > 0, actualSize != dmg.size {
            throw UpdateError.sizeMismatch(expected: dmg.size, actual: actualSize)
        }
        let digest = try Self.sha256(of: destination.path)
        guard digest == expected else { throw UpdateError.checksumMismatch(release.dmgName) }
        return VerifiedDownload(release: release, dmgPath: destination.path, sha256: digest)
    }

    func expectedChecksum(for name: String, from asset: ReleaseAsset) async throws -> String {
        let (data, response) = try await client.data(
            for: ReleaseFeed.request(asset.downloadURL, appVersion: appVersion, accept: "application/octet-stream"))
        guard (200..<300).contains(response.status) else { throw UpdateError.httpStatus(response.status) }
        guard data.count <= Self.maximumChecksumBytes else { throw UpdateError.missingChecksum(name) }
        guard let checksum = Self.checksum(for: name, in: String(decoding: data, as: UTF8.self)) else {
            throw UpdateError.missingChecksum(name)
        }
        return checksum
    }

    /// Finds `name` in `shasum -a 256` output (`<64 hex>  <name>`, or `<hex> *<name>` in binary mode).
    /// Returns the lowercased digest.
    public static func checksum(for name: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2 else { continue }
            let digest = fields[0].lowercased()
            var file = fields[1].trimmingCharacters(in: .whitespaces)
            if file.hasPrefix("*") { file.removeFirst() }
            guard file == name, digest.count == 64, digest.allSatisfy(\.isHexDigit) else { continue }
            return digest
        }
        return nil
    }

    /// Streaming SHA-256 (1 MiB at a time), lowercase hex.
    public static func sha256(of path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Turns raw byte counts into throttled `DownloadProgress` updates with an average rate.
private final class RateMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let start = Date()
    private var lastEmit = Date.distantPast
    private var received: Int64 = 0
    private var total: Int64?
    private let continuation: AsyncStream<DownloadProgress>.Continuation?

    init(total: Int64?, continuation: AsyncStream<DownloadProgress>.Continuation?) {
        self.total = total
        self.continuation = continuation
    }

    func update(received: Int64, total: Int64?) {
        let progress: DownloadProgress? = lock.withLock {
            self.received = received
            if let total { self.total = total }
            let now = Date()
            guard now.timeIntervalSince(lastEmit) >= 0.1 else { return nil }
            lastEmit = now
            return snapshot(now: now)
        }
        if let progress { continuation?.yield(progress) }
    }

    func finish() {
        let progress = lock.withLock { snapshot(now: Date()) }
        continuation?.yield(progress)
    }

    private func snapshot(now: Date) -> DownloadProgress {
        let elapsed = now.timeIntervalSince(start)
        let rate = elapsed > 0.2 ? Double(received) / elapsed : 0
        return DownloadProgress(received: received, total: total, bytesPerSecond: rate)
    }
}
