import Foundation

public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    /// The final URL after redirects.
    public let url: URL?

    public init(status: Int, url: URL?) {
        self.status = status
        self.url = url
    }
}

/// The updater's only way onto the network, so tests can substitute a fake. Implementations must
/// apply the host policy to every redirect.
public protocol HTTPClient: Sendable {
    /// GET into memory.
    func data(for request: URLRequest) async throws -> (Data, HTTPResponse)
    /// GET into `destination`, which must not exist yet. `progress(received, expected)` is called as
    /// bytes arrive; `expected` is nil when the server doesn't say. Throws `CancellationError` when the
    /// calling task is cancelled.
    func download(
        _ request: URLRequest, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> HTTPResponse
}

/// `URLSession` with an ephemeral configuration (no cookies, no cache, no credentials) and a delegate
/// that refuses any redirect outside `UpdateHostPolicy`. `file://` URLs (dev feed override only, and
/// only if the policy allows them) are read straight from disk.
public struct URLSessionHTTPClient: HTTPClient {
    let policy: UpdateHostPolicy

    public init(policy: UpdateHostPolicy) {
        self.policy = policy
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        return configuration
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPResponse) {
        guard let url = request.url else { throw UpdateError.invalidFeed("missing URL") }
        try policy.check(url)
        if url.isFileURL {
            return (try Data(contentsOf: url), HTTPResponse(status: 200, url: url))
        }
        let delegate = SessionDelegate(policy: policy, destination: nil, progress: nil)
        let session = URLSession(configuration: Self.configuration(), delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await mapCancellation { try await session.data(for: request) }
        if let blocked = delegate.blockedHost { throw UpdateError.hostNotAllowed(blocked) }
        guard let http = response as? HTTPURLResponse else { throw UpdateError.invalidFeed("not an HTTP response") }
        if let final = http.url { try policy.check(final) }
        return (data, HTTPResponse(status: http.statusCode, url: http.url))
    }

    public func download(
        _ request: URLRequest, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> HTTPResponse {
        guard let url = request.url else { throw UpdateError.downloadFailed("missing URL") }
        try policy.check(url)
        if url.isFileURL {
            try Self.copyFile(from: url, to: destination, progress: progress)
            return HTTPResponse(status: 200, url: url)
        }
        let delegate = SessionDelegate(policy: policy, destination: destination, progress: progress)
        let session = URLSession(configuration: Self.configuration(), delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Chunked local copy with progress, used for `file://` feeds.
    static func copyFile(from source: URL, to destination: URL, progress: @Sendable (Int64, Int64?) -> Void)
        throws
    {
        let total = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?
            .int64Value
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw UpdateError.downloadFailed("could not create \(destination.lastPathComponent)")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var copied: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            copied += Int64(chunk.count)
            progress(copied, total)
        }
    }

    private func mapCancellation<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }
}

/// Redirect guard + download bookkeeping for one session.
private final class SessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let policy: UpdateHostPolicy
    let destination: URL?
    let progress: (@Sendable (Int64, Int64?) -> Void)?

    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPResponse, any Error>?
    private var blocked: String?
    private var finishError: (any Error)?
    private var response: HTTPResponse?

    init(policy: UpdateHostPolicy, destination: URL?, progress: (@Sendable (Int64, Int64?) -> Void)?) {
        self.policy = policy
        self.destination = destination
        self.progress = progress
    }

    var blockedHost: String? { lock.withLock { blocked } }

    func start(_ continuation: CheckedContinuation<HTTPResponse, any Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if let url = request.url, policy.allows(url) {
            completionHandler(request)
        } else {
            lock.withLock { blocked = request.url?.host(percentEncoded: false) ?? request.url?.absoluteString ?? "?" }
            // nil = don't follow; the redirect response itself completes the task and is rejected below.
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        progress?(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        // The temporary file disappears when this method returns, so it is moved here.
        let http = downloadTask.response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        lock.withLock { response = HTTPResponse(status: status, url: http?.url) }
        guard (200..<300).contains(status), let destination else { return }
        if let final = http?.url, !policy.allows(final) {
            lock.withLock { blocked = final.host(percentEncoded: false) ?? final.absoluteString }
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { finishError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, blocked, finishError, response) = lock.withLock {
            let snapshot = (self.continuation, self.blocked, self.finishError, self.response)
            self.continuation = nil
            return snapshot
        }
        guard let continuation else { return }
        if let blocked {
            continuation.resume(throwing: UpdateError.hostNotAllowed(blocked))
        } else if let error = error as? URLError, error.code == .cancelled {
            continuation.resume(throwing: CancellationError())
        } else if let error {
            continuation.resume(throwing: UpdateError.downloadFailed(error.localizedDescription))
        } else if let finishError {
            continuation.resume(throwing: UpdateError.downloadFailed(finishError.localizedDescription))
        } else if let response {
            continuation.resume(returning: response)
        } else {
            let http = task.response as? HTTPURLResponse
            continuation.resume(returning: HTTPResponse(status: http?.statusCode ?? 0, url: http?.url))
        }
    }
}
