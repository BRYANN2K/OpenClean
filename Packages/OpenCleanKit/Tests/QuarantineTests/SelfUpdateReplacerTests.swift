import Foundation
import RuleKit
import TestSupport
import Testing

@testable import Quarantine

struct SelfUpdateReplacerTests {
    static let bundleID = "com.openclean"

    struct Fixture {
        let temp: TempDirectory
        let store: QuarantineStore
        let updates: URL
        let current: String
        let staged: String

        init() throws {
            temp = try TempDirectory()
            store = QuarantineStore(root: temp.url.appendingPathComponent("Support/Quarantine"))
            updates = temp.url.appendingPathComponent("Support/Updates")
            current = try temp.fakeApp("Applications/OpenClean.app", version: "0.2.0")
            staged = try temp.fakeApp("Support/Updates/0.3.0/staged-1/OpenClean.app", version: "0.3.0")
        }

        func replacer(
            move: (@Sendable (String, String) throws -> Void)? = nil, readOnly: Bool = false,
            writable: Bool = true
        ) -> SelfUpdateReplacer {
            SelfUpdateReplacer(
                store: store, updatesDirectory: updates, bundleIdentifier: SelfUpdateReplacerTests.bundleID,
                move: move ?? { try FileManager.default.moveItem(atPath: $0, toPath: $1) },
                isReadOnlyVolume: { _ in readOnly }, isWritable: { _ in writable })
        }
    }

    static func version(_ app: String) -> String? {
        let data = try? Data(contentsOf: URL(fileURLWithPath: app + "/Contents/Info.plist"))
        let plist = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
        return (plist as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    @Test func replacesAndKeepsPreviousVersionInQuarantine() throws {
        let f = try Fixture()
        let manifest = try f.replacer().replace(currentApp: f.current, with: f.staged)

        #expect(Self.version(f.current) == "0.3.0")
        #expect(FileStat.of(f.staged) == nil)
        let entry = try #require(manifest.entries.first)
        #expect(manifest.entries.count == 1)
        #expect(entry.ruleID == SelfUpdateReplacer.ruleID)
        #expect(entry.mode == .quarantine)
        #expect(entry.outcome == .quarantined)
        #expect(entry.originalPath == f.current)
        let stored = try #require(entry.storedPath)
        #expect(pathIsWithin(stored, f.store.itemsDirectory(manifest.id).path))
        #expect(Self.version(stored) == "0.2.0")
        #expect(try f.store.read(id: manifest.id) == manifest)
    }

    @Test func restoreBringsPreviousVersionBack() throws {
        let f = try Fixture()
        let manifest = try f.replacer().replace(currentApp: f.current, with: f.staged)
        let trashed = try f.temp.directory("FakeTrash")
        let restore = RestoreService(store: f.store) { path in
            let target = trashed + "/" + (path as NSString).lastPathComponent
            try FileManager.default.moveItem(atPath: path, toPath: target)
            return target
        }

        // Default conflict policy: the new version is in the way, so nothing happens.
        let skipped = try restore.restore(sessionID: manifest.id, onConflict: .skip)
        #expect(skipped.restored.isEmpty)
        #expect(Self.version(f.current) == "0.3.0")

        let report = try restore.restore(sessionID: manifest.id, onConflict: .replace)
        #expect(report.restored == [f.current])
        #expect(Self.version(f.current) == "0.2.0")
        #expect(Self.version(trashed + "/OpenClean.app") == "0.3.0")
    }

    @Test func rollsBackWhenInstallMoveFails() throws {
        let f = try Fixture()
        let staged = f.staged
        let replacer = f.replacer(move: { source, destination in
            if source == staged { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.moveItem(atPath: source, toPath: destination)
        })
        #expect(throws: SelfUpdateError.self) { try replacer.replace(currentApp: f.current, with: f.staged) }

        #expect(Self.version(f.current) == "0.2.0")
        #expect(Self.version(f.staged) == "0.3.0")
        let listing = try #require(f.store.listSessions().first)
        guard case .ok(let manifest) = listing else {
            Issue.record("damaged manifest")
            return
        }
        #expect(manifest.entries.first?.outcome == .failed)
        #expect(manifest.entries.first?.storedPath == nil)
        #expect(manifest.restorableEntries.isEmpty)
    }

    @Test func keepsPreviousVersionInHistoryWhenRollbackAlsoFails() throws {
        let f = try Fixture()
        let staged = f.staged
        let current = f.current
        let replacer = f.replacer(move: { source, destination in
            if source == staged || destination == current { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.moveItem(atPath: source, toPath: destination)
        })
        #expect(throws: SelfUpdateError.self) { try replacer.replace(currentApp: f.current, with: f.staged) }
        guard case .ok(let manifest) = try #require(f.store.listSessions().first) else {
            Issue.record("damaged manifest")
            return
        }
        #expect(manifest.entries.first?.outcome == .quarantined)
        #expect(manifest.restorableEntries.count == 1)
    }

    @Test func failedQuarantineMoveTouchesNothing() throws {
        let f = try Fixture()
        let replacer = f.replacer(move: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(throws: SelfUpdateError.self) { try replacer.replace(currentApp: f.current, with: f.staged) }
        #expect(Self.version(f.current) == "0.2.0")
        #expect(Self.version(f.staged) == "0.3.0")
    }

    @Test func refusesTranslocatedApp() throws {
        let f = try Fixture()
        let translocated = try f.temp.fakeApp("AppTranslocation/ABC/d/OpenClean.app")
        #expect(throws: SelfUpdateError.translocated) {
            try f.replacer().replace(currentApp: translocated, with: f.staged)
        }
        #expect(Self.version(f.staged) == "0.3.0")
    }

    @Test func refusesSymlinkedPaths() throws {
        let f = try Fixture()
        let link = try f.temp.symlink("Linked", to: f.temp.path + "/Applications")
        #expect(throws: SelfUpdateError.symlinkedPath(link + "/OpenClean.app")) {
            try f.replacer().replace(currentApp: link + "/OpenClean.app", with: f.staged)
        }
        let appLink = try f.temp.symlink("Other/OpenClean.app", to: f.current)
        #expect(throws: SelfUpdateError.notAnApp(appLink)) {
            try f.replacer().replace(currentApp: appLink, with: f.staged)
        }
        #expect(throws: SelfUpdateError.self) {
            try f.replacer().replace(
                currentApp: f.temp.path + "/Applications/../Applications/OpenClean.app", with: f.staged)
        }
        #expect(Self.version(f.current) == "0.2.0")
    }

    @Test func refusesUnwritableOrReadOnlyLocations() throws {
        let f = try Fixture()
        #expect(throws: SelfUpdateError.notWritable(f.current)) {
            try f.replacer(writable: false).replace(currentApp: f.current, with: f.staged)
        }
        #expect(throws: SelfUpdateError.readOnlyVolume(f.current)) {
            try f.replacer(readOnly: true).replace(currentApp: f.current, with: f.staged)
        }
        #expect(f.store.listSessions().isEmpty)
    }

    @Test func refusesReallyUnwritableParent() throws {
        let f = try Fixture()
        let parent = f.temp.path + "/Applications"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent) }
        let replacer = SelfUpdateReplacer(store: f.store, updatesDirectory: f.updates, bundleIdentifier: Self.bundleID)
        #expect(throws: SelfUpdateError.notWritable(f.current)) {
            try replacer.replace(currentApp: f.current, with: f.staged)
        }
        #expect(Self.version(f.current) == "0.2.0")
    }

    @Test func refusesWrongBundleIdentifiers() throws {
        let f = try Fixture()
        let other = try f.temp.fakeApp("Applications/Other.app", bundleID: "com.example.Other")
        #expect(throws: SelfUpdateError.wrongBundle(other)) {
            try f.replacer().replace(currentApp: other, with: f.staged)
        }
        let evil = try f.temp.fakeApp("Support/Updates/0.3.0/staged-2/OpenClean.app", bundleID: "com.example.Evil")
        #expect(throws: SelfUpdateError.wrongBundle(evil)) {
            try f.replacer().replace(currentApp: f.current, with: evil)
        }
        #expect(Self.version(f.current) == "0.2.0")
    }

    @Test func refusesStagedAppOutsideUpdates() throws {
        let f = try Fixture()
        let outside = try f.temp.fakeApp("Downloads/OpenClean.app", version: "0.3.0")
        #expect(throws: SelfUpdateError.stagedOutsideUpdates(outside)) {
            try f.replacer().replace(currentApp: f.current, with: outside)
        }
        // A symlink inside Updates pointing outside doesn't count either.
        let link = try f.temp.symlink("Support/Updates/0.3.0/link.app", to: outside)
        #expect(throws: SelfUpdateError.self) { try f.replacer().replace(currentApp: f.current, with: link) }
    }

    @Test func refusesDevelopmentBuilds() throws {
        let f = try Fixture()
        try f.temp.file("Repo/Package.swift")
        let dev = try f.temp.fakeApp("Repo/build/OpenClean.app")
        #expect(throws: SelfUpdateError.developmentBuild(dev)) {
            try f.replacer().replace(currentApp: dev, with: f.staged)
        }
        let swiftBuild = try f.temp.fakeApp("Repo/.build/debug/OpenClean.app")
        #expect(throws: SelfUpdateError.developmentBuild(swiftBuild)) {
            try f.replacer().replace(currentApp: swiftBuild, with: f.staged)
        }
    }

    @Test func refusesNonApps() throws {
        let f = try Fixture()
        let folder = try f.temp.directory("Applications/OpenClean")
        #expect(throws: SelfUpdateError.notAnApp(folder)) {
            try f.replacer().replace(currentApp: folder, with: f.staged)
        }
        #expect(throws: SelfUpdateError.notAnApp("relative/OpenClean.app")) {
            try f.replacer().replace(currentApp: "relative/OpenClean.app", with: f.staged)
        }
    }
}

struct UpdateStagingCleanerTests {
    @Test func removesVersionFoldersInsideUpdatesOnly() throws {
        let temp = try TempDirectory()
        let updates = temp.url.appendingPathComponent("Updates")
        try temp.file("Updates/0.3.0/OpenClean-0.3.0.dmg", bytes: 10)
        try temp.file("Updates/0.4.0/OpenClean-0.4.0.dmg", bytes: 10)
        let outside = try temp.file("Keep/important.txt", bytes: 3)
        let cleaner = UpdateStagingCleaner(updatesDirectory: updates)

        try cleaner.remove("0.3.0")
        #expect(FileStat.of(temp.path + "/Updates/0.3.0") == nil)
        #expect(FileStat.of(temp.path + "/Updates/0.4.0") != nil)

        for bad in ["", ".", "..", "../Keep", "0.4.0/../../Keep", "/Keep"] {
            #expect(throws: (any Error).self, "\(bad)") { try cleaner.remove(bad) }
        }
        #expect(FileStat.of(outside) != nil)
        try cleaner.remove("missing")  // no-op
    }

    @Test func neverFollowsSymlinks() throws {
        let temp = try TempDirectory()
        let victim = try temp.file("Victim/file.txt", bytes: 3)
        try temp.directory("Updates")
        try temp.symlink("Updates/0.3.0", to: temp.path + "/Victim")
        let cleaner = UpdateStagingCleaner(updatesDirectory: temp.url.appendingPathComponent("Updates"))
        #expect(cleaner.removeAll() == ["0.3.0"])
        #expect(FileStat.of(victim) != nil)
        #expect(FileStat.of(temp.path + "/Updates/0.3.0") == nil)
    }

    @Test func refusesSymlinkedUpdatesFolder() throws {
        let temp = try TempDirectory()
        let victim = try temp.file("Victim/0.3.0/file.txt", bytes: 3)
        try temp.symlink("Updates", to: temp.path + "/Victim")
        let cleaner = UpdateStagingCleaner(updatesDirectory: temp.url.appendingPathComponent("Updates"))
        try cleaner.remove("0.3.0")
        #expect(cleaner.removeAll().isEmpty)
        #expect(FileStat.of(victim) != nil)
    }

    @Test func removeAllKeepsTheNamedVersion() throws {
        let temp = try TempDirectory()
        try temp.directory("Updates/0.3.0")
        try temp.directory("Updates/0.4.0")
        try temp.file("Updates/stray.dmg", bytes: 1)
        let cleaner = UpdateStagingCleaner(updatesDirectory: temp.url.appendingPathComponent("Updates"))
        #expect(Set(cleaner.removeAll(keeping: "0.4.0")) == ["0.3.0", "stray.dmg"])
        #expect(FileStat.of(temp.path + "/Updates/0.4.0") != nil)
    }
}
