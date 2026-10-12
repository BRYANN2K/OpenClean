import Foundation
import RuleKit

public enum ConflictPolicy: String, Sendable, CaseIterable {
    case skip
    case keepBoth = "keep-both"
    case replace
}

public struct RestoreSkip: Sendable, Equatable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct RestoreReport: Sendable, Equatable {
    public var restored: [String] = []
    public var skipped: [RestoreSkip] = []

    public init() {}
}

/// Moves quarantined (or trashed) items back to where they came from.
public struct RestoreService: Sendable {
    let store: QuarantineStore
    let trash: TrashOperation

    public init(store: QuarantineStore, trash: @escaping TrashOperation = Remover.systemTrash) {
        self.store = store
        self.trash = trash
    }

    public func restore(sessionID: String, paths: Set<String>? = nil, onConflict: ConflictPolicy) throws -> RestoreReport {
        var manifest = try store.read(id: sessionID)
        var report = RestoreReport()
        let fileManager = FileManager.default

        for index in manifest.entries.indices {
            let entry = manifest.entries[index]
            if let paths, !paths.contains(entry.originalPath) { continue }
            guard [.quarantined, .trashed, .pending].contains(entry.outcome), let stored = entry.storedPath else {
                continue
            }
            guard FileStat.of(stored) != nil else {
                report.skipped.append(RestoreSkip(path: entry.originalPath, reason: "stored copy is missing"))
                continue
            }

            var destination = entry.originalPath
            if FileStat.of(destination) != nil {
                switch onConflict {
                case .skip:
                    report.skipped.append(
                        RestoreSkip(path: destination, reason: "a file already exists at the original location"))
                    continue
                case .keepBoth:
                    destination = Self.alternateName(for: destination)
                case .replace:
                    do {
                        _ = try trash(destination)
                    } catch {
                        report.skipped.append(RestoreSkip(path: destination, reason: error.localizedDescription))
                        continue
                    }
                }
            }

            do {
                try fileManager.createDirectory(
                    atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fileManager.moveItem(atPath: stored, toPath: destination)
                manifest.entries[index].outcome = .restored
                manifest.entries[index].reason = destination == entry.originalPath ? nil : "restored as \(destination)"
                report.restored.append(destination)
            } catch {
                report.skipped.append(RestoreSkip(path: entry.originalPath, reason: error.localizedDescription))
            }
        }
        try store.write(manifest)
        return report
    }

    /// "name (restored).ext", then "name (restored 2).ext", … until unused.
    public static func alternateName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent().path
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var attempt = 1
        while true {
            let suffix = attempt == 1 ? " (restored)" : " (restored \(attempt))"
            let candidate = directory + "/" + base + suffix + (ext.isEmpty ? "" : "." + ext)
            if FileStat.of(candidate) == nil { return candidate }
            attempt += 1
        }
    }
}
