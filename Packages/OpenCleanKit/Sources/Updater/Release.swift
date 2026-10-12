import Foundation

/// One downloadable file attached to a GitHub release.
public struct ReleaseAsset: Sendable, Equatable, Codable {
    public let name: String
    public let downloadURL: URL
    public let size: Int64

    public init(name: String, downloadURL: URL, size: Int64) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
    }
}

/// The latest published release, as read from the GitHub API (or the dev feed override).
public struct Release: Sendable, Equatable {
    public let version: SemanticVersion
    public let tagName: String
    public let name: String
    /// Release notes in Markdown.
    public let notes: String
    /// The release page on github.com; always offered as the manual fallback.
    public let htmlURL: URL
    public let publishedAt: Date?
    public let assets: [ReleaseAsset]

    public init(
        version: SemanticVersion, tagName: String, name: String, notes: String, htmlURL: URL, publishedAt: Date?,
        assets: [ReleaseAsset]
    ) {
        self.version = version
        self.tagName = tagName
        self.name = name
        self.notes = notes
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
        self.assets = assets
    }

    /// `OpenClean-X.Y.Z.dmg`, the name `make release-assets` gives the disk image.
    public var dmgName: String { "OpenClean-\(version.core).dmg" }
    public static let checksumsName = "SHA256SUMS.txt"

    public var dmg: ReleaseAsset? { assets.first { $0.name == dmgName } }
    public var checksums: ReleaseAsset? { assets.first { $0.name == Self.checksumsName } }

    /// A release can be installed in place only when it has both the disk image and the checksum list.
    /// Otherwise the app offers "View on GitHub" only.
    public var isInstallable: Bool { dmg != nil && checksums != nil && !version.isPrerelease }
}

public enum UpdateError: Error, Equatable, CustomStringConvertible {
    case hostNotAllowed(String)
    case httpStatus(Int)
    case rateLimited
    case noPublishedRelease
    case invalidFeed(String)
    case notInstallable
    case missingChecksum(String)
    case checksumMismatch(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case downloadFailed(String)
    case stagingFailed(String)
    case invalidBundle(String)
    case signatureInvalid(String)
    /// The running app is Developer ID signed and the update isn't signed by the same team.
    case publisherMismatch(String)

    public var description: String {
        switch self {
        case .hostNotAllowed(let host): "OpenClean only downloads updates from GitHub, not from \(host)."
        case .httpStatus(let code): "GitHub answered with HTTP \(code)."
        case .rateLimited: "GitHub is limiting requests right now. Try again in a little while."
        case .noPublishedRelease: "No OpenClean release has been published yet."
        case .invalidFeed(let reason): "The release information could not be read (\(reason))."
        case .notInstallable: "This release has no disk image and checksum to install from."
        case .missingChecksum(let name): "SHA256SUMS.txt does not list \(name)."
        case .checksumMismatch(let name): "\(name) did not match its published checksum, so it was not used."
        case .sizeMismatch(let expected, let actual):
            "The download is \(actual) bytes but the release says \(expected), so it was not used."
        case .downloadFailed(let reason): "The download failed: \(reason)"
        case .stagingFailed(let reason): "The update could not be prepared: \(reason)"
        case .invalidBundle(let reason): "The downloaded app is not a valid OpenClean update: \(reason)"
        case .signatureInvalid(let reason): "The downloaded app's code signature is invalid: \(reason)"
        case .publisherMismatch(let reason):
            "The downloaded app isn't from OpenClean's publisher, so it was not installed: \(reason)."
        }
    }
}
