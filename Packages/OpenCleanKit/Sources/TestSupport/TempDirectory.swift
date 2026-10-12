import Foundation

/// A uniquely named temporary directory with a canonical (symlink-free) path,
/// removed when the object is released. Test-only helper.
public final class TempDirectory: @unchecked Sendable {
    public let url: URL
    public var path: String { url.path }

    public init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("openclean-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let resolved = realpath(base.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        url = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Creates a file filled with `bytes` non-zero bytes and returns its absolute path.
    @discardableResult
    public func file(_ relativePath: String, bytes: Int = 0, modified: Date? = nil) throws -> String {
        let target = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: target)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
        }
        return target.path
    }

    @discardableResult
    public func directory(_ relativePath: String, modified: Date? = nil) throws -> String {
        let target = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
        }
        return target.path
    }

    @discardableResult
    public func symlink(_ relativePath: String, to destination: String) throws -> String {
        let target = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
        return target.path
    }
}

extension TempDirectory {
    /// A minimal app bundle (`Contents/Info.plist` + a fake executable) for update tests.
    @discardableResult
    public func fakeApp(
        _ relativePath: String, bundleID: String = "com.openclean", version: String = "0.2.0"
    ) throws -> String {
        let app = url.appendingPathComponent(relativePath, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version, "CFBundleExecutable": "OpenClean",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("version \(version)".utf8).write(to: contents.appendingPathComponent("MacOS/OpenClean"))
        return app.path
    }
}
