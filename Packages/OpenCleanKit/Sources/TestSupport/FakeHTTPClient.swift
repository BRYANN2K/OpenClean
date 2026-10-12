import Foundation
import Updater

/// Serves canned responses by URL; never touches the network. Unknown URLs answer 404.
/// Downloads write the canned body to the destination, reporting progress in a few chunks.
public final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    public struct Response: Sendable {
        public var status: Int
        public var body: Data
        /// Delay before a download completes (for cancellation tests).
        public var delay: Duration?

        public init(status: Int = 200, body: Data, delay: Duration? = nil) {
            self.status = status
            self.body = body
            self.delay = delay
        }
    }

    private let lock = NSLock()
    private var responses: [URL: Response] = [:]
    private var recorded: [URLRequest] = []

    public init() {}

    public var requests: [URLRequest] { lock.withLock { recorded } }

    public func respond(_ url: URL, status: Int = 200, body: Data, delay: Duration? = nil) {
        lock.withLock { responses[url] = Response(status: status, body: body, delay: delay) }
    }

    public func respond(_ url: URL, status: Int = 200, text: String) {
        respond(url, status: status, body: Data(text.utf8))
    }

    private func response(for request: URLRequest) -> Response {
        lock.withLock {
            recorded.append(request)
            return request.url.flatMap { responses[$0] } ?? Response(status: 404, body: Data())
        }
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPResponse) {
        let response = response(for: request)
        return (response.body, HTTPResponse(status: response.status, url: request.url))
    }

    public func download(
        _ request: URLRequest, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> HTTPResponse {
        let response = response(for: request)
        if let delay = response.delay { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        guard (200..<300).contains(response.status) else {
            return HTTPResponse(status: response.status, url: request.url)
        }
        let total = Int64(response.body.count)
        progress(total / 2, total)
        try response.body.write(to: destination, options: .withoutOverwriting)
        progress(total, total)
        return HTTPResponse(status: response.status, url: request.url)
    }
}

/// A GitHub-shaped "latest release" JSON body for tests.
public func releaseJSON(
    tag: String, assets: [(name: String, url: String, size: Int)], body: String = "## Features\n- Something new",
    prerelease: Bool = false
) -> Data {
    let assetObjects: [[String: Any]] = assets.map {
        ["name": $0.name, "browser_download_url": $0.url, "size": $0.size]
    }
    let object: [String: Any] = [
        "tag_name": tag, "name": "OpenClean \(tag.drop { $0 == "v" })", "body": body,
        "html_url": "https://github.com/leoAnimesh/OpenClean/releases/tag/\(tag)",
        "published_at": "2026-10-01T12:00:00Z", "draft": false, "prerelease": prerelease, "assets": assetObjects,
    ]
    return try! JSONSerialization.data(withJSONObject: object)
}
