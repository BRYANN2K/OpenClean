import Foundation
import OpenCleanKit
import Quarantine
import RuleKit
import ScanEngine

/// Stable, versioned JSON output. Changing a field name or meaning requires bumping `schema`.
public enum JSONReport {
    static let schema = 1

    struct ItemDTO: Encodable {
        let path: String
        let bytes: Int64
        let reportOnly: Bool
        let hint: String?
    }

    struct RuleDTO: Encodable {
        let id: String
        let name: String
        let category: String
        let safety: String
        let status: String
        let totalBytes: Int64
        let itemCount: Int
        let items: [ItemDTO]
        let errors: [String]
    }

    struct ScanDTO: Encodable {
        let schema: Int
        let complete: Bool
        let totalBytes: Int64
        let rules: [RuleDTO]
    }

    struct RuleInfoDTO: Encodable {
        let id: String
        let name: String
        let category: String
        let safety: String
        let deleteMode: String
        let explain: String
        let paths: [String]
        let probe: String?
        let requires: [String]
    }

    struct RulesDTO: Encodable {
        let schema: Int
        let rules: [RuleInfoDTO]
    }

    struct EntryDTO: Encodable {
        let path: String
        let bytes: Int64
        let rule: String
        let mode: String
        let outcome: String
        let storedPath: String?
        let reason: String?
    }

    struct SessionDTO: Encodable {
        let id: String
        let createdAt: Date?
        let purgedAt: Date?
        let damaged: Bool
        let deletedBytes: Int64
        let quarantinedBytes: Int64
        let skippedCount: Int
        let entries: [EntryDTO]
    }

    struct HistoryDTO: Encodable {
        let schema: Int
        let sessions: [SessionDTO]
    }

    struct CleanupDTO: Encodable {
        let schema: Int
        let session: SessionDTO
    }

    struct PlanDTO: Encodable {
        let schema: Int
        let itemCount: Int
        let immediateBytes: Int64
        let quarantineBytes: Int64
        let adminItemCount: Int
        let paths: [String]
    }

    struct SkipDTO: Encodable {
        let path: String
        let reason: String
    }

    struct RestoreDTO: Encodable {
        let schema: Int
        let restored: [String]
        let skipped: [SkipDTO]
    }

    public static func scan(_ result: ScanResult) throws -> String {
        try encode(
            ScanDTO(
                schema: schema, complete: result.isComplete, totalBytes: result.totalSize,
                rules: result.rules.map { ruleResult in
                    RuleDTO(
                        id: ruleResult.rule.id, name: ruleResult.rule.name,
                        category: ruleResult.rule.category.rawValue, safety: ruleResult.rule.safety.rawValue,
                        status: status(ruleResult.status), totalBytes: ruleResult.totalSize,
                        itemCount: ruleResult.items.count,
                        items: ruleResult.items.map {
                            ItemDTO(path: $0.path, bytes: $0.size, reportOnly: $0.reportOnly, hint: $0.hint)
                        },
                        errors: ruleResult.errors)
                }))
    }

    public static func rules(_ rules: [Rule]) throws -> String {
        try encode(
            RulesDTO(
                schema: schema,
                rules: rules.map {
                    RuleInfoDTO(
                        id: $0.id, name: $0.name, category: $0.category.rawValue, safety: $0.safety.rawValue,
                        deleteMode: $0.effectiveDeleteMode.rawValue, explain: $0.explain, paths: $0.paths,
                        probe: $0.probe, requires: $0.requires.map(\.rawValue))
                }))
    }

    public static func plan(_ plan: CleanupPlan) throws -> String {
        try encode(
            PlanDTO(
                schema: schema, itemCount: plan.itemCount, immediateBytes: plan.immediateBytes,
                quarantineBytes: plan.quarantineBytes, adminItemCount: plan.adminRequests.count,
                paths: plan.requests.map(\.item.path)))
    }

    public static func cleanup(_ report: RemovalReport) throws -> String {
        try encode(CleanupDTO(schema: schema, session: session(.ok(report.manifest))))
    }

    public static func history(_ listings: [SessionListing]) throws -> String {
        try encode(HistoryDTO(schema: schema, sessions: listings.map(session)))
    }

    public static func restore(_ report: RestoreReport) throws -> String {
        try encode(
            RestoreDTO(
                schema: schema, restored: report.restored,
                skipped: report.skipped.map { SkipDTO(path: $0.path, reason: $0.reason) }))
    }

    static func status(_ status: RuleScanStatus) -> String {
        switch status {
        case .scanned: "scanned"
        case .needsFullDiskAccess: "needs_full_disk_access"
        case .skippedAppRunning(let id): "app_running:\(id)"
        case .cancelled: "cancelled"
        }
    }

    static func session(_ listing: SessionListing) -> SessionDTO {
        switch listing {
        case .ok(let manifest):
            SessionDTO(
                id: manifest.id, createdAt: manifest.createdAt, purgedAt: manifest.purgedAt, damaged: false,
                deletedBytes: manifest.deletedBytes, quarantinedBytes: manifest.quarantinedBytes,
                skippedCount: manifest.skippedEntries.count,
                entries: manifest.entries.map {
                    EntryDTO(
                        path: $0.originalPath, bytes: $0.size, rule: $0.ruleID, mode: $0.mode.rawValue,
                        outcome: $0.outcome.rawValue, storedPath: $0.storedPath, reason: $0.reason)
                })
        case .damaged(let id, let created):
            SessionDTO(
                id: id, createdAt: created, purgedAt: nil, damaged: true, deletedBytes: 0, quarantinedBytes: 0,
                skippedCount: 0, entries: [])
        }
    }

    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
