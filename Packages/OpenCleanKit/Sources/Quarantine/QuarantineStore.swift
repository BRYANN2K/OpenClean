import Foundation
import RuleKit

public enum SessionListing: Sendable, Identifiable {
    case ok(SessionManifest)
    case damaged(id: String, created: Date?)

    public var id: String {
        switch self {
        case .ok(let manifest): manifest.id
        case .damaged(let id, _): id
        }
    }

    public var date: Date? {
        switch self {
        case .ok(let manifest): manifest.createdAt
        case .damaged(_, let created): created
        }
    }
}

public enum QuarantineError: Error, Equatable {
    case sessionNotFound(String)
}

/// Owns `Quarantine/<session-id>/{manifest.json, items/}`.
public struct QuarantineStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func sessionDirectory(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    public func itemsDirectory(_ id: String) -> URL {
        sessionDirectory(id).appendingPathComponent("items", isDirectory: true)
    }
    func manifestURL(_ id: String) -> URL { sessionDirectory(id).appendingPathComponent("manifest.json") }

    public func createSession(now: Date = .now) throws -> SessionManifest {
        let id = Self.makeSessionID(now: now)
        try FileManager.default.createDirectory(at: itemsDirectory(id), withIntermediateDirectories: true)
        let manifest = SessionManifest(id: id, createdAt: now.wholeSeconds)
        try write(manifest)
        return manifest
    }

    /// Atomic write (temp file + rename), so a crash never leaves a half-written manifest.
    public func write(_ manifest: SessionManifest) throws {
        try Self.encoder().encode(manifest).write(to: manifestURL(manifest.id), options: .atomic)
    }

    public func read(id: String) throws -> SessionManifest {
        guard FileManager.default.fileExists(atPath: sessionDirectory(id).path) else {
            throw QuarantineError.sessionNotFound(id)
        }
        return try Self.decoder().decode(SessionManifest.self, from: Data(contentsOf: manifestURL(id)))
    }

    public func listSessions() -> [SessionListing] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let listings: [SessionListing] = names
            .filter { FileStat.of(sessionDirectory($0).path)?.isDirectory == true }
            .map { name in
                if let manifest = try? read(id: name) { return .ok(manifest) }
                let attributes = try? FileManager.default.attributesOfItem(atPath: sessionDirectory(name).path)
                return .damaged(id: name, created: attributes?[.creationDate] as? Date)
            }
        return listings.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    static func makeSessionID(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(4)
        return formatter.string(from: now) + "-" + suffix
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
