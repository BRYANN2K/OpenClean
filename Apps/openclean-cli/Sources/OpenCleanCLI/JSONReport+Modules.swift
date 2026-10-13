import AppInventory
import Foundation
import SpaceKit
import SystemMonitor

/// JSON for `apps`, `space` and `performance`. Same contract as the rest of `JSONReport`: `"schema": 1`,
/// nil keys omitted, renaming or changing the meaning of a field needs a schema bump.
extension JSONReport {
    // MARK: Apps

    struct LeftoverDTO: Encodable {
        let path: String
        let kind: String
        let match: String
        let scope: String
        let bytes: Int64
        let reportOnly: Bool
        let selectedByDefault: Bool

        init(_ leftover: Leftover) {
            path = leftover.path
            kind = leftover.kind.rawValue
            match = leftover.match.rawValue
            scope = leftover.scope.rawValue
            bytes = leftover.size
            reportOnly = leftover.isReportOnly
            selectedByDefault = leftover.isSelectedByDefault
        }
    }

    struct AppDTO: Encodable {
        let name: String
        let path: String
        let bundleID: String?
        let version: String?
        let bytes: Int64
        let status: String
        let removable: Bool
        let requiresAdministrator: Bool
        let running: Bool
        let lastUsed: Date?
        /// Removable (user-scope) leftovers only; report-only ones in /Library are not counted.
        let leftoverBytes: Int64
        let leftovers: [LeftoverDTO]

        init(_ entry: AppListing) {
            let app = entry.app
            name = app.name
            path = app.path
            bundleID = app.bundleID
            version = app.version
            bytes = app.size
            status = app.status.rawValue
            removable = app.status.isRemovable
            requiresAdministrator = app.status.requiresAdministrator
            running = app.isRunning
            lastUsed = app.lastUsed
            leftoverBytes = entry.leftovers.filter { !$0.isReportOnly }.reduce(0) { $0 + $1.size }
            leftovers = entry.leftovers.map(LeftoverDTO.init)
        }
    }

    struct AppsDTO: Encodable {
        let schema: Int
        let apps: [AppDTO]
    }

    struct UninstallPlanDTO: Encodable {
        let schema: Int
        let app: AppDTO
        /// What would be moved to quarantine: the app first, then the chosen leftovers.
        let paths: [String]
        let totalBytes: Int64
        let requiresAdministrator: Bool
    }

    public static func apps(_ listings: [AppListing]) throws -> String {
        try encode(AppsDTO(schema: schema, apps: listings.map(AppDTO.init)))
    }

    public static func uninstallPlan(_ plan: UninstallPlan) throws -> String {
        try encode(
            UninstallPlanDTO(
                schema: schema, app: AppDTO(plan.listing), paths: plan.paths, totalBytes: plan.totalBytes,
                requiresAdministrator: plan.listing.app.status.requiresAdministrator))
    }

    // MARK: Space

    struct LargeFileDTO: Encodable {
        let path: String
        let name: String
        let kind: String
        let bytes: Int64
        let lastOpened: Date?
        let modified: Date
        let userContent: Bool
    }

    struct LargeFilesDTO: Encodable {
        let schema: Int
        let roots: [String]
        let complete: Bool
        let unreadableCount: Int
        let minimumBytes: Int64
        let notOpenedForDays: Int?
        let totalBytes: Int64
        let files: [LargeFileDTO]
    }

    struct DuplicateFileDTO: Encodable {
        let path: String
        let bytes: Int64
        let created: Date
        let modified: Date
        let userContent: Bool
    }

    struct DuplicateGroupDTO: Encodable {
        let sha256: String
        let bytes: Int64
        let reclaimableBytes: Int64
        let suggestedKeep: String
        let files: [DuplicateFileDTO]
    }

    struct DuplicatesDTO: Encodable {
        let schema: Int
        let roots: [String]
        let complete: Bool
        let unreadableCount: Int
        let unhashableCount: Int
        let reclaimableBytes: Int64
        let groups: [DuplicateGroupDTO]
    }

    /// `files` are the ones that pass `filter` (the finder's result is not filtered by age).
    public static func largeFiles(_ result: LargeFileResult, files: [LargeFile], filter: LargeFileFilter) throws
        -> String
    {
        try encode(
            LargeFilesDTO(
                schema: schema, roots: result.roots, complete: result.isComplete,
                unreadableCount: result.unreadableCount, minimumBytes: filter.minimumSize,
                notOpenedForDays: filter.notOpenedForDays, totalBytes: files.reduce(0) { $0 + $1.size },
                files: files.map {
                    LargeFileDTO(
                        path: $0.path, name: $0.name, kind: $0.kind.rawValue, bytes: $0.size, lastOpened: $0.lastOpened,
                        modified: $0.modified, userContent: $0.isUserContent)
                }))
    }

    public static func duplicates(_ result: DuplicateResult) throws -> String {
        try encode(
            DuplicatesDTO(
                schema: schema, roots: result.roots, complete: result.isComplete,
                unreadableCount: result.unreadableCount, unhashableCount: result.unhashable,
                reclaimableBytes: result.reclaimable,
                groups: result.groups.map { group in
                    DuplicateGroupDTO(
                        sha256: group.id, bytes: group.logicalSize, reclaimableBytes: group.reclaimable,
                        suggestedKeep: group.suggestedKeep,
                        files: group.files.map {
                            DuplicateFileDTO(
                                path: $0.path, bytes: $0.size, created: $0.created, modified: $0.modified,
                                userContent: $0.isUserContent)
                        })
                }))
    }

    // MARK: Performance

    struct MemoryDTO: Encodable {
        let usedBytes: UInt64
        let totalBytes: UInt64
        let appBytes: UInt64
        let wiredBytes: UInt64
        let compressedBytes: UInt64
        let pressure: String
    }

    struct DiskDTO: Encodable {
        let availableBytes: Int64
        let totalBytes: Int64
    }

    struct ProcessGroupDTO: Encodable {
        let name: String
        let bundlePath: String?
        let pid: Int32?
        let processCount: Int
        /// Percent of one core, as Activity Monitor shows it; one decimal.
        let cpuPercent: Double
        let residentBytes: UInt64
    }

    struct PerformanceDTO: Encodable {
        let schema: Int
        let intervalSeconds: Double
        /// Whole-machine CPU use, 0…1 across all cores, rounded to three decimals.
        let cpuUsage: Double?
        let memory: MemoryDTO?
        let disk: DiskDTO?
        let processesMeasured: Int
        let topCPU: [ProcessGroupDTO]
        let topMemory: [ProcessGroupDTO]
    }

    public static func performance(_ snapshot: PerformanceSnapshot) throws -> String {
        func group(_ group: ProcessGroup) -> ProcessGroupDTO {
            ProcessGroupDTO(
                name: group.name, bundlePath: group.bundlePath, pid: group.mainPID ?? group.processes.first?.pid,
                processCount: group.processes.count, cpuPercent: (group.cpuPercent * 10).rounded() / 10,
                residentBytes: group.residentBytes)
        }
        let monitor = snapshot.monitor
        return try encode(
            PerformanceDTO(
                schema: schema, intervalSeconds: snapshot.interval,
                cpuUsage: monitor.cpu.map { ($0 * 1_000).rounded() / 1_000 },
                memory: monitor.memory.map {
                    MemoryDTO(
                        usedBytes: $0.used, totalBytes: $0.total, appBytes: $0.appMemory, wiredBytes: $0.wired,
                        compressedBytes: $0.compressed, pressure: $0.pressure.rawValue)
                },
                disk: monitor.disk.map { DiskDTO(availableBytes: $0.available, totalBytes: $0.total) },
                processesMeasured: (monitor.groups ?? []).reduce(0) { $0 + $1.processes.count },
                topCPU: snapshot.topCPU.map(group), topMemory: snapshot.topMemory.map(group)))
    }
}
