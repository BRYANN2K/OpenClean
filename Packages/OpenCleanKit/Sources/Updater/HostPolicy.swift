import Foundation

/// Which URLs the updater may talk to. Checked before every request and on every redirect.
///
/// Only HTTPS to GitHub's API, its website and the two hosts release downloads redirect to. `file://`
/// is accepted only when the developer feed override (`OPENCLEAN_UPDATE_FEED`) is in use.
public struct UpdateHostPolicy: Sendable, Equatable {
    public static let allowedHosts: Set<String> = [
        "api.github.com", "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]

    public let allowsFileURLs: Bool

    public init(allowsFileURLs: Bool = false) {
        self.allowsFileURLs = allowsFileURLs
    }

    public func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "file" { return allowsFileURLs && url.host(percentEncoded: false).map(\.isEmpty) ?? true }
        guard scheme == "https", url.user == nil, url.password == nil,
            let host = url.host(percentEncoded: false)?.lowercased()
        else { return false }
        if let port = url.port, port != 443 { return false }
        return Self.allowedHosts.contains(host)
    }

    /// Throws `UpdateError.hostNotAllowed` unless `allows(url)`.
    public func check(_ url: URL) throws {
        guard allows(url) else {
            throw UpdateError.hostNotAllowed(url.host(percentEncoded: false) ?? url.absoluteString)
        }
    }
}
