import Foundation
import Testing

/// Only Quarantine and Privilege may remove files. Everything else in the product must not.
struct RemovalGuardTests {
    static let forbidden = ["removeItem(", "trashItem(", "unlink(", "rmdir(", "/bin/rm",
        "unlinkat(", "removefile(", "recycle(",
    ]
    static let allowedModules: Set<String> = ["Quarantine", "Privilege", "TestSupport"]

    @Test func onlyQuarantineAndPrivilegeRemoveFiles() throws {
        // <repo>/Packages/OpenCleanKit/Tests/QuarantineTests/RemovalGuardTests.swift
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var violations: [String] = []
        var scanned = 0

        let kitSources = repo.appendingPathComponent("Packages/OpenCleanKit/Sources")
        for module in try FileManager.default.contentsOfDirectory(atPath: kitSources.path)
        where !Self.allowedModules.contains(module) {
            violations += try Self.scan(kitSources.appendingPathComponent(module), scanned: &scanned)
        }
        let apps = repo.appendingPathComponent("Apps")
        if FileManager.default.fileExists(atPath: apps.path) {
            violations += try Self.scan(apps, scanned: &scanned, skipTests: true)
        }

        #expect(scanned > 0)
        #expect(violations.isEmpty, "file removal outside Quarantine/Privilege: \(violations)")
    }

    static func scan(_ root: URL, scanned: inout Int, skipTests: Bool = false) throws -> [String] {
        var violations: [String] = []
        let enumerator = FileManager.default.enumerator(atPath: root.path)
        while let relative = enumerator?.nextObject() as? String {
            guard relative.hasSuffix(".swift") else { continue }
            if skipTests && relative.contains("/Tests/") { continue }
            let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            scanned += 1
            for token in forbidden where text.contains(token) {
                violations.append("\(root.lastPathComponent)/\(relative): \(token)")
            }
        }
        return violations
    }
}
