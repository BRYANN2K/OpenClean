import Foundation

/// Reads the latest published release from the GitHub API.
///
/// The request carries only `Accept: application/vnd.github+json`, `User-Agent: OpenClean/<version>`
/// and a fixed `Accept-Language: en` (so the system language isn't sent). No cookies, tokens or IDs.
///
/// Developer override: set `OPENCLEAN_UPDATE_FEED` to a URL (or absolute path) of a JSON file shaped
/// like the GitHub "latest release" response. `file://` URLs are then allowed, for the feed and for its
/// asset links; any https URL must still be on the GitHub allowlist.
public struct ReleaseFeed: Sendable {
    public static let defaultURL = URL(string: "https://api.github.com/repos/leoAnimesh/OpenClean/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/leoAnimesh/OpenClean/releases")!
    public static let overrideVariable = "OPENCLEAN_UPDATE_FEED"
    /// Larger responses are refused rather than parsed.
    static let maximumFeedBytes = 5 << 20

    public let url: URL
    public let policy: UpdateHostPolicy
    let client: any HTTPClient
    let appVersion: String

    public init(
        client: any HTTPClient, appVersion: String, url: URL = ReleaseFeed.defaultURL,
        policy: UpdateHostPolicy = UpdateHostPolicy()
    ) {
        self.client = client
        self.appVersion = appVersion
        self.url = url
        self.policy = policy
    }

    /// Feed URL and host policy for an environment: the GitHub API, or the dev override.
    public static func source(environment: [String: String]) -> (url: URL, policy: UpdateHostPolicy) {
        guard let raw = environment[overrideVariable]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return (defaultURL, UpdateHostPolicy())
        }
        let url = raw.utf8.first == 0x2F ? URL(fileURLWithPath: raw) : (URL(string: raw) ?? defaultURL)
        return (url, UpdateHostPolicy(allowsFileURLs: true))
    }

    /// The headers every updater request carries, and nothing else.
    public static func request(_ url: URL, appVersion: String, accept: String = "application/vnd.github+json")
        -> URLRequest
    {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("OpenClean/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }

    public func latest() async throws -> Release {
        try policy.check(url)
        let (data, response) = try await client.data(for: Self.request(url, appVersion: appVersion))
        switch response.status {
        case 200..<300: break
        case 404: throw UpdateError.noPublishedRelease
        case 403, 429: throw UpdateError.rateLimited
        default: throw UpdateError.httpStatus(response.status)
        }
        guard data.count <= Self.maximumFeedBytes else { throw UpdateError.invalidFeed("response too large") }
        return try Self.parse(data, policy: policy)
    }

    struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let downloadURL: String
            let size: Int64?

            enum CodingKeys: String, CodingKey {
                case name, size
                case downloadURL = "browser_download_url"
            }
        }
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: String?
        let publishedAt: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?

        enum CodingKeys: String, CodingKey {
            case name, body, draft, prerelease, assets
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case publishedAt = "published_at"
        }
    }

    static func parse(_ data: Data, policy: UpdateHostPolicy) throws -> Release {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw UpdateError.invalidFeed("unexpected JSON")
        }
        guard let version = SemanticVersion(payload.tagName) else {
            throw UpdateError.invalidFeed("tag \(payload.tagName) is not a version")
        }
        if payload.draft == true { throw UpdateError.noPublishedRelease }
        // /releases/latest never returns pre-releases; a feed that does is treated as having no update.
        let flaggedPrerelease = payload.prerelease == true
        let effective =
            flaggedPrerelease && !version.isPrerelease
            ? SemanticVersion(
                major: version.major, minor: version.minor, patch: version.patch, prerelease: "prerelease")
            : version
        let assets = (payload.assets ?? []).compactMap { asset -> ReleaseAsset? in
            guard let url = URL(string: asset.downloadURL) else { return nil }
            return ReleaseAsset(name: asset.name, downloadURL: url, size: max(asset.size ?? 0, 0))
        }
        var htmlURL = releasesPage
        if let raw = payload.htmlURL, let url = URL(string: raw), url.scheme?.lowercased() == "https",
            policy.allows(url)
        {
            htmlURL = url
        }
        let publishedAt = payload.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        return Release(
            version: effective, tagName: payload.tagName, name: payload.name ?? "OpenClean \(version.core)",
            notes: payload.body ?? "", htmlURL: htmlURL, publishedAt: publishedAt, assets: assets)
    }
}
