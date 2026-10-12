# OpenClean Core + Cleanup + Smart Scan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build OpenClean's shared cleanup core (rule packs, scan engine, quarantine with undo, admin-prompt deletion, Full Disk Access handling), the `openclean` CLI, and the SwiftUI app's Smart Scan / Cleanup / History / Settings screens.

**Architecture:** One SwiftPM package at the repo root. Library targets under `Packages/OpenCleanKit/Sources/` hold all logic and never import SwiftUI or AppKit. `OpenCleanKit` is a facade (`OpenCleanCoordinator`) used by both front ends. The CLI (`Apps/openclean-cli`) and the SwiftUI app (`Apps/OpenClean`) are thin; the app is a SwiftPM executable wrapped into `OpenClean.app` by a Makefile. Only the `Quarantine` and `Privilege` modules may remove files, enforced by a guard test.

**Tech Stack:** Swift 6 (language mode 6), SwiftUI + Observation, macOS 14+, SwiftPM (tools 6.0), Swift Testing, Yams 5.x (YAML), swift-argument-parser 1.5+, Apple `swift format` (bundled with the toolchain), GitHub Actions `macos-15`.

**Spec:** `docs/superpowers/specs/2026-10-12-openclean-core-cleanup-design.md`

## Global Constraints

- Minimum macOS 14 (Sonoma); Apple Silicon and Intel. `platforms: [.macOS(.v14)]`.
- Swift 6 language mode (swift-tools-version 6.0). Code must compile with strict concurrency.
- Only third-party dependencies: `jpsim/Yams` (from 5.1.0) and `apple/swift-argument-parser` (from 1.5.0).
- No network access, telemetry, accounts or upsell anywhere.
- Only `Quarantine` and `Privilege` may call file-removal APIs (`removeItem`, `trashItem`, `unlink`, `rmdir`, `/bin/rm`); `Privilege` is invoked only by `Quarantine`.
- No module under `Packages/OpenCleanKit/Sources` imports SwiftUI or AppKit.
- Tests never touch the real home directory, real Trash, real LaunchAgents or a real admin prompt; home, trash, admin executor and command runner are injected.
- Rule schema `version: 1`. Categories exactly: `system`, `user`, `browsers`, `developer`, `ai`, `mail`, `trash`, `ios`. Safety exactly: `regenerable`, `review`, `caution`.
- Safety defaults: `regenerable` → selected, `immediate`; `review` → not selected, `quarantine`; `caution` → not selected, `quarantine`, visible only with Advanced.
- `requires: admin` only on `regenerable` rules, and those always delete immediately (no root-owned data in quarantine).
- Quarantine root: `~/Library/Application Support/OpenClean/Quarantine/<session-id>/`; retention default 7 days, range 1–90.
- CLI JSON carries `"schema": 1`. Exit codes: `0` success, `1` error or aborted, `2` completed with skipped items.
- App bundle id `io.github.leoanimesh.OpenClean`; LaunchAgent label `io.github.leoanimesh.openclean.purge`.
- Commits are authored by the repo-local identity `leoAnimesh <mondalarup808@gmail.com>` (already configured) and end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Spec Clarifications Made in This Plan

These refine the approved spec; Task 4 updates the spec text for #1 and #2.

1. **APFS clones:** sizes use allocated blocks, which handles sparse files exactly. Cloned files are counted at full allocation because macOS has no public API for shared-block accounting, so freed space can be overstated for clones.
2. **Deny-list is stricter:** a path is also denied when it *contains* a protected location (e.g. `~/Library`, `/Library`, `/Users`), and `~/Library/Mobile Documents` is protected as a whole subtree, not only its root.
3. **Probes return `ProbeFinding`** (path, report-only flag, hint) rather than `ScanItem`; the engine applies the same resolution, deny-list and sizing to findings.
4. **Overlapping matches** across rules are counted once: the first rule in load order keeps the item.
5. **Extra targets:** `ProcessKit` (subprocess runner), `OpenCleanKit` (coordinator), `OpenCleanCLI` (testable CLI library), `OpenCleanAppModel` (testable view model), `TestSupport` (test helpers).
6. **Formatter:** Apple's bundled `swift format` instead of nicklockwood/SwiftFormat (no extra install).
7. **App build:** SwiftPM executable bundled by `make app`, not `xcodebuild`.
8. **Running-app detection** uses `proc_listallpids` + bundle lookup (pure Darwin), so the core needs no AppKit.

## Review Focus

1. **The same files matched by two rules** (e.g. `~/Library/Caches/*` and `~/Library/Caches/Homebrew/*`) — a user expects each file counted and removed once. Test: Task 5 `overlappingRulesCountEachFileOnce`.
2. **A file regenerated or deleted by its app between scan and clean** — expect it skipped with a reason, never an error that aborts the session. Tests: Task 9 `skipsMissingItem` / `skipsChangedItem`, Task 10 `missingItemIsSkippedNotFailed`.
3. **Hostile or unusual file names** (quotes, `$(...)`, leading `-`, spaces, newlines, emoji) — expect exact removal/restore of only that file. Tests: Task 7 `hostileNamesAreRemovedLiterally`, Task 11 `restoresUnusualNames`.
4. **A crash mid-cleanup** — expect items already moved to quarantine to still be restorable from the manifest. Test: Task 11 `restoresPendingEntriesAfterCrash`.
5. **Cancelling a scan** — expect a prompt return with partial results clearly marked incomplete. Tests: Task 5 `cancellationReturnsIncompleteResult`, Task 17 `cancelScanShowsPartialResults`.

## File Structure

```
Package.swift                                   all targets (grows task by task)
Makefile                                        app bundle, install, dist
Rules/*.yaml                                    bundled rule packs
Packages/OpenCleanKit/Sources/
  TestSupport/      TempDirectory, FakeProcessChecker, FakeCommandRunner
  ProcessKit/       CommandRunner, ProcessCommandRunner
  RuleKit/          RuleModels, ByteSize, RulePackLoader, FileSystem, PathExpander,
                    DenyList, GlobMatcher, RuleLinter, AppPaths
  ScanEngine/       Models, ProcessChecker, FileSizer, ItemBuilder, PathRuleScanner,
                    Probe, ScanEngine
  Probes/           XcodeSimulatorsProbe, HomebrewCacheProbe, DockerDiskImageProbe,
                    TimeMachineSnapshotsProbe, StandardProbes
  Privilege/        AdminCommandBuilder, AdminExecutor
  Quarantine/       Manifest, QuarantineStore, OpenFiles, PreDeleteChecker, Remover,
                    RestoreService, Purger, PurgeSchedule
  Permissions/      FullDiskAccessChecker, SignatureTracker
  OpenCleanKit/     Settings, RulesLocator, RuleCatalog, CleanupPlan, Coordinator
Packages/OpenCleanKit/Tests/<Target>Tests/      one test target per library
Apps/openclean-cli/Sources/OpenCleanCLI/        commands, JSONReport, TextReport, CleanSelection
Apps/openclean-cli/Sources/openclean/main.swift
Apps/openclean-cli/Tests/OpenCleanCLITests/     golden + integration tests (Golden/ resources)
Apps/OpenClean/Sources/OpenCleanAppModel/       AppModel
Apps/OpenClean/Sources/OpenCleanApp/            SwiftUI views
Apps/OpenClean/Tests/OpenCleanAppModelTests/
Apps/OpenClean/Info.plist
.github/workflows/{ci,release}.yml, docs, templates
```

---

### Task 1: Package scaffold, RuleKit models and YAML loading

**Files:**
- Create: `Package.swift`, `.gitignore`
- Create: `Packages/OpenCleanKit/Sources/TestSupport/TempDirectory.swift`
- Create: `Packages/OpenCleanKit/Sources/RuleKit/RuleModels.swift`
- Create: `Packages/OpenCleanKit/Sources/RuleKit/ByteSize.swift`
- Create: `Packages/OpenCleanKit/Sources/RuleKit/RulePackLoader.swift`
- Test: `Packages/OpenCleanKit/Tests/RuleKitTests/ByteSizeTests.swift`, `Packages/OpenCleanKit/Tests/RuleKitTests/RulePackLoaderTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum SafetyLevel: String { regenerable, review, caution }` with `defaultDeleteMode: DeleteMode`, `isSelectedByDefault: Bool`
  - `enum DeleteMode: String, Codable { immediate, quarantine }`
  - `enum RuleCategory: String, CaseIterable { system, user, browsers, developer, ai, mail, trash, ios }` with `displayName: String`
  - `enum Requirement: String { fullDiskAccess = "full_disk_access", admin }`
  - `struct RuleConditions { appNotRunning: [String]; minAgeDays: Int?; minSize: ByteSize? }`
  - `struct Rule { id, name, category, explain, paths: [String], probe: String?, safety, deleteMode: DeleteMode?, conditions, exclude: [String], requires: [Requirement] }` with `effectiveDeleteMode`, `needs(_ requirement: Requirement) -> Bool`
  - `struct RulePack { pack: String; version: Int; rules: [Rule]; sourcePath: String? }`
  - `struct ByteSize { bytes: Int64 }` with `static func parse(_:) -> ByteSize?`, `static func format(_ bytes: Int64) -> String`
  - `enum RulePackError: Error, Equatable { unreadable, invalidYAML, unknownKey, unsupportedVersion }`
  - `struct RulePackLoader { load(from: URL) throws -> RulePack; load(yaml:sourcePath:) throws -> RulePack; loadDirectory(_:) -> (packs: [RulePack], errors: [RulePackError]) }`
  - `final class TempDirectory { url, path; file(_:bytes:modified:) -> String; directory(_:modified:) -> String; symlink(_:to:) -> String }` (TestSupport)

- [ ] **Step 1: Create the package manifest and ignore file**

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenClean",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "TestSupport",
            path: "Packages/OpenCleanKit/Sources/TestSupport"
        ),
        .target(
            name: "RuleKit",
            dependencies: [.product(name: "Yams", package: "Yams")],
            path: "Packages/OpenCleanKit/Sources/RuleKit"
        ),
        .testTarget(
            name: "RuleKitTests",
            dependencies: ["RuleKit", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/RuleKitTests"
        ),
    ]
)
```

`.gitignore`:

```
.build/
build/
.swiftpm/
*.xcodeproj/
DerivedData/
.DS_Store
```

- [ ] **Step 2: Create the test helper**

`Packages/OpenCleanKit/Sources/TestSupport/TempDirectory.swift`:

```swift
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
```

- [ ] **Step 3: Write the failing tests**

`Packages/OpenCleanKit/Tests/RuleKitTests/ByteSizeTests.swift`:

```swift
import Testing
@testable import RuleKit

struct ByteSizeTests {
    @Test func parsesDecimalUnits() {
        #expect(ByteSize.parse("10MB") == ByteSize(bytes: 10_000_000))
        #expect(ByteSize.parse("1.5 GB") == ByteSize(bytes: 1_500_000_000))
        #expect(ByteSize.parse("500kb") == ByteSize(bytes: 500_000))
        #expect(ByteSize.parse("512") == ByteSize(bytes: 512))
        #expect(ByteSize.parse("2TB") == ByteSize(bytes: 2_000_000_000_000))
    }

    @Test func rejectsGarbageAndNegatives() {
        #expect(ByteSize.parse("ten MB") == nil)
        #expect(ByteSize.parse("-5MB") == nil)
        #expect(ByteSize.parse("") == nil)
    }
}
```

`Packages/OpenCleanKit/Tests/RuleKitTests/RulePackLoaderTests.swift`:

```swift
import Foundation
import Testing
import TestSupport
@testable import RuleKit

struct RulePackLoaderTests {
    let loader = RulePackLoader()

    @Test func decodesEveryField() throws {
        let yaml = """
            pack: dev-tools
            version: 1
            rules:
              - id: xcode.derived-data
                name: Xcode DerivedData
                category: developer
                explain: Build intermediates Xcode regenerates on next build.
                paths:
                  - "~/Library/Developer/Xcode/DerivedData/*"
                safety: regenerable
                conditions:
                  app_not_running: com.apple.dt.Xcode
                  min_age_days: 3
                  min_size: 10MB
                exclude:
                  - "*/ModuleCache.noindex"
                requires: [full_disk_access]
            """
        let pack = try loader.load(yaml: yaml, sourcePath: "dev-tools.yaml")
        let rule = try #require(pack.rules.first)
        #expect(pack.pack == "dev-tools")
        #expect(pack.sourcePath == "dev-tools.yaml")
        #expect(rule.category == .developer)
        #expect(rule.paths == ["~/Library/Developer/Xcode/DerivedData/*"])
        #expect(rule.conditions.appNotRunning == ["com.apple.dt.Xcode"])
        #expect(rule.conditions.minAgeDays == 3)
        #expect(rule.conditions.minSize == ByteSize(bytes: 10_000_000))
        #expect(rule.exclude == ["*/ModuleCache.noindex"])
        #expect(rule.requires == [.fullDiskAccess])
        #expect(rule.needs(.fullDiskAccess))
        #expect(rule.effectiveDeleteMode == .immediate)
    }

    @Test func appliesDefaultsForOptionalFields() throws {
        let yaml = """
            pack: ai
            version: 1
            rules:
              - id: huggingface.hub
                name: Hugging Face cache
                category: ai
                explain: Downloaded again on next use.
                paths: ["~/.cache/huggingface/hub/*"]
                safety: review
                conditions:
                  app_not_running: [a.one, a.two]
            """
        let rule = try #require(try loader.load(yaml: yaml, sourcePath: "ai.yaml").rules.first)
        #expect(rule.effectiveDeleteMode == .quarantine)
        #expect(rule.exclude.isEmpty)
        #expect(rule.requires.isEmpty)
        #expect(rule.probe == nil)
        #expect(rule.conditions.appNotRunning == ["a.one", "a.two"])
        #expect(rule.conditions.minAgeDays == nil)
    }

    @Test func rejectsUnknownRuleKey() {
        let yaml = """
            pack: p
            version: 1
            rules:
              - id: a.b
                name: A
                category: user
                explain: x
                pathz: ["~/x"]
                safety: review
            """
        #expect(throws: RulePackError.unknownKey(path: "p.yaml", key: "pathz", context: "a.b")) {
            try loader.load(yaml: yaml, sourcePath: "p.yaml")
        }
    }

    @Test func rejectsUnknownConditionKey() {
        let yaml = """
            pack: p
            version: 1
            rules:
              - id: a.b
                name: A
                category: user
                explain: x
                paths: ["~/x"]
                safety: review
                conditions:
                  older_than: 3
            """
        #expect(throws: RulePackError.unknownKey(path: "p.yaml", key: "older_than", context: "a.b.conditions")) {
            try loader.load(yaml: yaml, sourcePath: "p.yaml")
        }
    }

    @Test func rejectsUnsupportedVersion() {
        let yaml = "pack: p\nversion: 2\nrules: []\n"
        #expect(throws: RulePackError.unsupportedVersion(path: "p.yaml", version: 2)) {
            try loader.load(yaml: yaml, sourcePath: "p.yaml")
        }
    }

    @Test func rejectsInvalidEnumValue() {
        let yaml = """
            pack: p
            version: 1
            rules:
              - id: a.b
                name: A
                category: banana
                explain: x
                paths: ["~/x"]
                safety: review
            """
        #expect(throws: RulePackError.self) { try loader.load(yaml: yaml, sourcePath: "p.yaml") }
    }

    @Test func loadsDirectoryAndCollectsErrors() throws {
        let dir = try TempDirectory()
        try "pack: good\nversion: 1\nrules: []\n".write(
            toFile: dir.path + "/good.yaml", atomically: true, encoding: .utf8)
        try "pack: bad\nversion: 1\nrules:\n  - nope: 1\n".write(
            toFile: dir.path + "/bad.yml", atomically: true, encoding: .utf8)
        try "ignored".write(toFile: dir.path + "/notes.txt", atomically: true, encoding: .utf8)

        let (packs, errors) = loader.loadDirectory(dir.url)
        #expect(packs.map(\.pack) == ["good"])
        #expect(errors.count == 1)
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test --filter RuleKitTests`
Expected: build FAILS — `cannot find 'ByteSize' in scope` / `cannot find 'RulePackLoader' in scope` (the RuleKit target has no sources yet, so SwiftPM may instead report that the target has no source files).

- [ ] **Step 5: Implement the models**

`Packages/OpenCleanKit/Sources/RuleKit/ByteSize.swift`:

```swift
import Foundation

/// A byte count that decodes from an integer or a decimal string such as "10MB" or "1.5 GB".
public struct ByteSize: Decodable, Sendable, Equatable, Comparable, CustomStringConvertible {
    public let bytes: Int64

    public init(bytes: Int64) {
        self.bytes = bytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int64.self) {
            guard number >= 0 else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "size must be >= 0")
            }
            bytes = number
            return
        }
        let text = try container.decode(String.self)
        guard let parsed = ByteSize.parse(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid size '\(text)'")
        }
        bytes = parsed.bytes
    }

    /// Parses decimal (1000-based, matching Finder) sizes: B, KB, MB, GB, TB. Case-insensitive.
    public static func parse(_ text: String) -> ByteSize? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard !trimmed.isEmpty else { return nil }
        let units: [(suffix: String, factor: Double)] = [
            ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1),
        ]
        for unit in units where trimmed.hasSuffix(unit.suffix) {
            let number = trimmed.dropLast(unit.suffix.count).trimmingCharacters(in: .whitespaces)
            guard let value = Double(number), value >= 0 else { return nil }
            return ByteSize(bytes: Int64(value * unit.factor))
        }
        guard let value = Int64(trimmed), value >= 0 else { return nil }
        return ByteSize(bytes: value)
    }

    public static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func < (lhs: ByteSize, rhs: ByteSize) -> Bool { lhs.bytes < rhs.bytes }

    public var description: String { ByteSize.format(bytes) }
}
```

`Packages/OpenCleanKit/Sources/RuleKit/RuleModels.swift`:

```swift
import Foundation

public enum SafetyLevel: String, Codable, Sendable, CaseIterable {
    case regenerable, review, caution

    public var defaultDeleteMode: DeleteMode { self == .regenerable ? .immediate : .quarantine }
    public var isSelectedByDefault: Bool { self == .regenerable }
}

public enum DeleteMode: String, Codable, Sendable {
    case immediate, quarantine
}

public enum RuleCategory: String, Codable, Sendable, CaseIterable {
    case system, user, browsers, developer, ai, mail, trash, ios

    public var displayName: String {
        switch self {
        case .system: "System Junk"
        case .user: "User Caches & Logs"
        case .browsers: "Browser Caches"
        case .developer: "Developer Tools"
        case .ai: "AI Models & Caches"
        case .mail: "Mail Attachments"
        case .trash: "Trash"
        case .ios: "iOS Backups"
        }
    }
}

public enum Requirement: String, Codable, Sendable {
    case fullDiskAccess = "full_disk_access"
    case admin
}

public struct RuleConditions: Decodable, Sendable, Equatable {
    public var appNotRunning: [String]
    public var minAgeDays: Int?
    public var minSize: ByteSize?

    public init(appNotRunning: [String] = [], minAgeDays: Int? = nil, minSize: ByteSize? = nil) {
        self.appNotRunning = appNotRunning
        self.minAgeDays = minAgeDays
        self.minSize = minSize
    }

    enum CodingKeys: String, CodingKey {
        case appNotRunning = "app_not_running"
        case minAgeDays = "min_age_days"
        case minSize = "min_size"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try? container.decode([String].self, forKey: .appNotRunning) {
            appNotRunning = list
        } else if let single = try container.decodeIfPresent(String.self, forKey: .appNotRunning) {
            appNotRunning = [single]
        } else {
            appNotRunning = []
        }
        minAgeDays = try container.decodeIfPresent(Int.self, forKey: .minAgeDays)
        minSize = try container.decodeIfPresent(ByteSize.self, forKey: .minSize)
    }
}

public struct Rule: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var category: RuleCategory
    public var explain: String
    public var paths: [String]
    public var probe: String?
    public var safety: SafetyLevel
    public var deleteMode: DeleteMode?
    public var conditions: RuleConditions
    public var exclude: [String]
    public var requires: [Requirement]

    public init(
        id: String, name: String, category: RuleCategory, explain: String,
        paths: [String] = [], probe: String? = nil, safety: SafetyLevel,
        deleteMode: DeleteMode? = nil, conditions: RuleConditions = RuleConditions(),
        exclude: [String] = [], requires: [Requirement] = []
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.explain = explain
        self.paths = paths
        self.probe = probe
        self.safety = safety
        self.deleteMode = deleteMode
        self.conditions = conditions
        self.exclude = exclude
        self.requires = requires
    }

    enum CodingKeys: String, CodingKey {
        case id, name, category, explain, paths, probe, safety, conditions, exclude, requires
        case deleteMode = "delete_mode"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decode(RuleCategory.self, forKey: .category)
        explain = try c.decode(String.self, forKey: .explain)
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        probe = try c.decodeIfPresent(String.self, forKey: .probe)
        safety = try c.decode(SafetyLevel.self, forKey: .safety)
        deleteMode = try c.decodeIfPresent(DeleteMode.self, forKey: .deleteMode)
        conditions = try c.decodeIfPresent(RuleConditions.self, forKey: .conditions) ?? RuleConditions()
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        requires = try c.decodeIfPresent([Requirement].self, forKey: .requires) ?? []
    }

    public var effectiveDeleteMode: DeleteMode { deleteMode ?? safety.defaultDeleteMode }

    public func needs(_ requirement: Requirement) -> Bool { requires.contains(requirement) }
}

public struct RulePack: Decodable, Sendable, Equatable {
    public var pack: String
    public var version: Int
    public var rules: [Rule]
    /// File the pack was loaded from; not part of the YAML.
    public var sourcePath: String? = nil

    enum CodingKeys: String, CodingKey { case pack, version, rules }

    public init(pack: String, version: Int = 1, rules: [Rule], sourcePath: String? = nil) {
        self.pack = pack
        self.version = version
        self.rules = rules
        self.sourcePath = sourcePath
    }
}
```

`Packages/OpenCleanKit/Sources/RuleKit/RulePackLoader.swift`:

```swift
import Foundation
import Yams

public enum RulePackError: Error, Equatable, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    case invalidYAML(path: String, reason: String)
    case unknownKey(path: String, key: String, context: String)
    case unsupportedVersion(path: String, version: Int)

    public var description: String {
        switch self {
        case .unreadable(let path, let reason): "\(path): cannot read file (\(reason))"
        case .invalidYAML(let path, let reason): "\(path): invalid rule pack (\(reason))"
        case .unknownKey(let path, let key, let context): "\(path): unknown key '\(key)' in \(context)"
        case .unsupportedVersion(let path, let version):
            "\(path): schema version \(version) is not supported (expected \(RulePackLoader.supportedVersion))"
        }
    }
}

public struct RulePackLoader: Sendable {
    public static let supportedVersion = 1
    static let packKeys: Set<String> = ["pack", "version", "rules"]
    static let ruleKeys: Set<String> = [
        "id", "name", "category", "explain", "paths", "probe", "safety",
        "delete_mode", "conditions", "exclude", "requires",
    ]
    static let conditionKeys: Set<String> = ["app_not_running", "min_age_days", "min_size"]

    public init() {}

    public func load(from url: URL) throws -> RulePack {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw RulePackError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        return try load(yaml: text, sourcePath: url.path)
    }

    public func load(yaml: String, sourcePath: String) throws -> RulePack {
        let raw: Any?
        do {
            raw = try Yams.load(yaml: yaml)
        } catch {
            throw RulePackError.invalidYAML(path: sourcePath, reason: "\(error)")
        }
        guard let root = raw as? [String: Any] else {
            throw RulePackError.invalidYAML(path: sourcePath, reason: "top level must be a mapping")
        }
        try checkKeys(root, allowed: Self.packKeys, path: sourcePath, context: "pack")
        if let rules = root["rules"] as? [[String: Any]] {
            for (index, rule) in rules.enumerated() {
                let context = (rule["id"] as? String) ?? "rule #\(index + 1)"
                try checkKeys(rule, allowed: Self.ruleKeys, path: sourcePath, context: context)
                if let conditions = rule["conditions"] as? [String: Any] {
                    try checkKeys(
                        conditions, allowed: Self.conditionKeys, path: sourcePath,
                        context: "\(context).conditions")
                }
            }
        }

        var pack: RulePack
        do {
            pack = try YAMLDecoder().decode(RulePack.self, from: yaml)
        } catch {
            throw RulePackError.invalidYAML(path: sourcePath, reason: "\(error)")
        }
        guard pack.version == Self.supportedVersion else {
            throw RulePackError.unsupportedVersion(path: sourcePath, version: pack.version)
        }
        pack.sourcePath = sourcePath
        return pack
    }

    /// Loads every `*.yaml` / `*.yml` file in `directory`, sorted by name.
    /// Invalid packs are reported in `errors`; valid packs still load.
    public func loadDirectory(_ directory: URL) -> (packs: [RulePack], errors: [RulePackError]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var packs: [RulePack] = []
        var errors: [RulePackError] = []
        for name in names.sorted() where name.hasSuffix(".yaml") || name.hasSuffix(".yml") {
            do {
                packs.append(try load(from: directory.appendingPathComponent(name)))
            } catch let error as RulePackError {
                errors.append(error)
            } catch {
                errors.append(.unreadable(path: directory.appendingPathComponent(name).path, reason: "\(error)"))
            }
        }
        return (packs, errors)
    }

    private func checkKeys(_ dict: [String: Any], allowed: Set<String>, path: String, context: String) throws {
        for key in dict.keys.sorted() where !allowed.contains(key) {
            throw RulePackError.unknownKey(path: path, key: key, context: context)
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter RuleKitTests`
Expected: PASS — 9 tests in `ByteSizeTests` and `RulePackLoaderTests`.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Package.resolved .gitignore Packages
git commit -m "feat(rulekit): add rule models and YAML rule pack loader" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Path expansion, deny-list and glob matching

**Files:**
- Create: `Packages/OpenCleanKit/Sources/RuleKit/FileSystem.swift`
- Create: `Packages/OpenCleanKit/Sources/RuleKit/PathExpander.swift`
- Create: `Packages/OpenCleanKit/Sources/RuleKit/DenyList.swift`
- Create: `Packages/OpenCleanKit/Sources/RuleKit/GlobMatcher.swift`
- Test: `Packages/OpenCleanKit/Tests/RuleKitTests/PathTests.swift`, `Packages/OpenCleanKit/Tests/RuleKitTests/DenyListTests.swift`, `Packages/OpenCleanKit/Tests/RuleKitTests/GlobMatcherTests.swift`

**Interfaces:**
- Consumes: Task 1 `TempDirectory`.
- Produces:
  - `func realPath(_ path: String) -> String?`
  - `struct FileStat { device: Int32; inode: UInt64; linkCount: UInt16; ownerUID: UInt32; allocatedBytes: Int64; modificationDate: Date; isDirectory: Bool; isSymlink: Bool; static func of(_ path: String) -> FileStat? }` (uses `lstat`, never follows a final symlink)
  - `struct PathExpander { home: String; init(home:); expand(_ pattern: String) -> String }`
  - `struct DenyList { home: String; init(home:); denialReason(for path: String) -> String?; isDenied(_:) -> Bool }`
  - `struct GlobResult { matches: [String]; errors: [String] }`
  - `struct GlobMatcher { init(); match(_ absolutePattern: String) -> GlobResult; static func literalPrefix(of:) -> String; static func hasWildcard(_:) -> Bool }`

- [ ] **Step 1: Write the failing tests**

`Packages/OpenCleanKit/Tests/RuleKitTests/PathTests.swift`:

```swift
import Foundation
import Testing
import TestSupport
@testable import RuleKit

struct PathTests {
    @Test func expandsTildeOnlyAtStart() {
        let expander = PathExpander(home: "/Users/tester/")
        #expect(expander.home == "/Users/tester")
        #expect(expander.expand("~") == "/Users/tester")
        #expect(expander.expand("~/Library/Caches/*") == "/Users/tester/Library/Caches/*")
        #expect(expander.expand("/Library/Caches/~x") == "/Library/Caches/~x")
    }

    @Test func fileStatReportsSymlinkWithoutFollowing() throws {
        let dir = try TempDirectory()
        let target = try dir.file("real.bin", bytes: 4096)
        let link = try dir.symlink("link", to: target)
        let linkStat = try #require(FileStat.of(link))
        let fileStat = try #require(FileStat.of(target))
        #expect(linkStat.isSymlink)
        #expect(!fileStat.isSymlink)
        #expect(fileStat.allocatedBytes >= 4096)
        #expect(realPath(link) == target)
        #expect(FileStat.of(dir.path + "/missing") == nil)
    }
}
```

`Packages/OpenCleanKit/Tests/RuleKitTests/DenyListTests.swift`:

```swift
import Testing
@testable import RuleKit

struct DenyListTests {
    let deny = DenyList(home: "/Users/tester")

    @Test(arguments: [
        "/", "/System/Library/Caches", "/usr/bin/true", "/bin/ls", "/sbin",
        "/Users/tester", "/Users/tester/Documents/report.pdf", "/Users/tester/Desktop/x",
        "/Users/tester/Library/Keychains/login.keychain-db", "/Library/Keychains/System.keychain",
        "/Users/tester/Library/Mail/V10", "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/a",
        "/Applications/Safari.app", "/Applications/Xcode.app/Contents/Developer",
        "/Users/tester/Applications/Foo.app/Contents",
        "/Users/tester/Pictures/Photos Library.photoslibrary/database",
        // ancestors of protected locations
        "/Users", "/Users/tester/Library", "/Library", "/Applications", "/Users/tester/Pictures", "/usr",
    ])
    func deniesProtectedPaths(path: String) {
        #expect(deny.isDenied(path), "expected \(path) to be denied")
    }

    @Test(arguments: [
        "/usr/local/Cellar/x", "/Library/Caches/com.example", "/private/var/log/system.log.0.gz",
        "/Users/tester/Library/Caches/com.example", "/Users/tester/.npm/_cacache",
        "/Users/tester/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/a.pdf",
        "/Applications/Utilities.txt", "/Users/tester/Pictures/holiday.jpg",
    ])
    func allowsOrdinaryPaths(path: String) {
        #expect(!deny.isDenied(path), "expected \(path) to be allowed: \(deny.denialReason(for: path) ?? "")")
    }
}
```

`Packages/OpenCleanKit/Tests/RuleKitTests/GlobMatcherTests.swift`:

```swift
import Foundation
import Testing
import TestSupport
@testable import RuleKit

struct GlobMatcherTests {
    @Test func literalPrefixStopsAtFirstWildcard() {
        #expect(GlobMatcher.literalPrefix(of: "/a/b/*/c") == "/a/b")
        #expect(GlobMatcher.literalPrefix(of: "/a/b/c") == "/a/b/c")
        #expect(GlobMatcher.literalPrefix(of: "/a/**/x") == "/a")
        #expect(GlobMatcher.literalPrefix(of: "/*") == "/")
    }

    @Test func starMatchesHiddenAndVisibleChildren() throws {
        let dir = try TempDirectory()
        try dir.file("Caches/a/f", bytes: 1)
        try dir.file("Caches/.hidden/f", bytes: 1)
        try dir.file("Caches/b.txt", bytes: 1)
        let result = GlobMatcher().match(dir.path + "/Caches/*")
        #expect(result.matches == [dir.path + "/Caches/.hidden", dir.path + "/Caches/a", dir.path + "/Caches/b.txt"])
        #expect(result.errors.isEmpty)
    }

    @Test func literalComponentAfterWildcard() throws {
        let dir = try TempDirectory()
        try dir.file("Chrome/Default/Cache/x", bytes: 1)
        try dir.file("Chrome/Profile 1/Cache/x", bytes: 1)
        try dir.file("Chrome/Profile 2/Other/x", bytes: 1)
        let result = GlobMatcher().match(dir.path + "/Chrome/*/Cache")
        #expect(result.matches == [dir.path + "/Chrome/Default/Cache", dir.path + "/Chrome/Profile 1/Cache"])
    }

    @Test func doubleStarMatchesAnyDepth() throws {
        let dir = try TempDirectory()
        try dir.file("p/a/cache2/x", bytes: 1)
        try dir.file("p/b/c/cache2/x", bytes: 1)
        try dir.file("p/cache2/x", bytes: 1)
        let result = GlobMatcher().match(dir.path + "/p/**/cache2")
        #expect(Set(result.matches) == [dir.path + "/p/a/cache2", dir.path + "/p/b/c/cache2", dir.path + "/p/cache2"])
    }

    @Test func noWildcardMatchesOnlyExistingPath() throws {
        let dir = try TempDirectory()
        try dir.directory(".ollama/models")
        #expect(GlobMatcher().match(dir.path + "/.ollama/models").matches == [dir.path + "/.ollama/models"])
        #expect(GlobMatcher().match(dir.path + "/.ollama/nothing").matches.isEmpty)
    }

    @Test func neverTraversesSymlinkedDirectories() throws {
        let dir = try TempDirectory()
        try dir.file("outside/Cache/secret", bytes: 1)
        try dir.directory("Chrome")
        try dir.symlink("Chrome/Linked", to: dir.path + "/outside")
        let result = GlobMatcher().match(dir.path + "/Chrome/*/Cache")
        #expect(result.matches.isEmpty)
    }

    @Test func returnsSymlinkEntriesThemselvesForScannerToFilter() throws {
        let dir = try TempDirectory()
        try dir.directory("Caches")
        try dir.symlink("Caches/evil", to: "/")
        #expect(GlobMatcher().match(dir.path + "/Caches/*").matches == [dir.path + "/Caches/evil"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RuleKitTests`
Expected: build FAILS — `cannot find 'PathExpander' in scope`, `cannot find 'DenyList' in scope`, `cannot find 'GlobMatcher' in scope`.

- [ ] **Step 3: Implement**

`Packages/OpenCleanKit/Sources/RuleKit/FileSystem.swift`:

```swift
import Darwin
import Foundation

/// Canonical absolute path with every symlink resolved, or nil if the path does not exist.
public func realPath(_ path: String) -> String? {
    guard let resolved = Darwin.realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// `lstat` snapshot of a path. Never follows a final symlink.
public struct FileStat: Sendable, Equatable {
    public let device: Int32
    public let inode: UInt64
    public let linkCount: UInt16
    public let ownerUID: UInt32
    /// Allocated bytes on disk (st_blocks * 512); sparse regions are not counted.
    public let allocatedBytes: Int64
    public let modificationDate: Date
    public let isDirectory: Bool
    public let isSymlink: Bool

    public static func of(_ path: String) -> FileStat? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        let seconds = TimeInterval(st.st_mtimespec.tv_sec)
        let nanos = TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
        return FileStat(
            device: st.st_dev,
            inode: st.st_ino,
            linkCount: st.st_nlink,
            ownerUID: st.st_uid,
            allocatedBytes: Int64(st.st_blocks) * 512,
            modificationDate: Date(timeIntervalSince1970: seconds + nanos),
            isDirectory: type == S_IFDIR,
            isSymlink: type == S_IFLNK
        )
    }
}

/// Removes duplicate and trailing slashes. Does not touch `/private` (unlike `standardizingPath`).
func normalizedPath(_ path: String) -> String {
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    return "/" + parts.joined(separator: "/")
}

/// True when `ancestor` equals `path` or is one of its parent directories.
func isAncestorOrEqual(_ ancestor: String, of path: String) -> Bool {
    if ancestor == "/" { return true }
    return path == ancestor || path.hasPrefix(ancestor + "/")
}
```

`Packages/OpenCleanKit/Sources/RuleKit/PathExpander.swift`:

```swift
import Foundation

/// Expands a leading `~` to an injected home directory (never the process's real home).
public struct PathExpander: Sendable, Equatable {
    public let home: String

    public init(home: String) {
        self.home = normalizedPath(home)
    }

    public func expand(_ pattern: String) -> String {
        if pattern == "~" { return home }
        if pattern.hasPrefix("~/") { return home + pattern.dropFirst(1) }
        return pattern
    }
}
```

`Packages/OpenCleanKit/Sources/RuleKit/DenyList.swift`:

```swift
import Foundation

/// Locations OpenClean must never remove, regardless of what a rule pack says.
/// A path is denied if it is a protected location, is inside one, or contains one.
public struct DenyList: Sendable {
    public let home: String
    private let subtrees: [String]
    private let exact: [String]
    private let allowedInside: [String]
    private let bundleParents: [String]
    private let photosParent: String

    public init(home: String) {
        let h = normalizedPath(home)
        self.home = h
        subtrees = [
            "/System", "/bin", "/sbin", "/usr",
            "\(h)/Documents", "\(h)/Desktop",
            "\(h)/Library/Keychains", "/Library/Keychains",
            "\(h)/Library/Mail", "\(h)/Library/Mobile Documents",
        ]
        exact = ["/", h, "/usr/local"]
        allowedInside = ["/usr/local"]
        bundleParents = ["/Applications", "\(h)/Applications"]
        photosParent = "\(h)/Pictures"
    }

    public func isDenied(_ path: String) -> Bool { denialReason(for: path) != nil }

    public func denialReason(for rawPath: String) -> String? {
        let path = normalizedPath(rawPath)

        for location in exact where path == location {
            return "protected location \(location)"
        }
        for root in subtrees where isAncestorOrEqual(root, of: path) {
            if allowedInside.contains(where: { isAncestorOrEqual($0, of: path) }) { continue }
            return "inside protected location \(root)"
        }
        for parent in bundleParents where path.hasPrefix(parent + "/") {
            let first = path.dropFirst(parent.count + 1).split(separator: "/").first ?? ""
            if first.hasSuffix(".app") { return "application bundle \(parent)/\(first)" }
        }
        if path.hasPrefix(photosParent + "/") {
            let first = path.dropFirst(photosParent.count + 1).split(separator: "/").first ?? ""
            if first.hasSuffix(".photoslibrary") { return "Photos library \(photosParent)/\(first)" }
        }
        let containedRoots = subtrees + exact.filter { $0 != "/" } + bundleParents + [photosParent]
        for root in containedRoots where path != "/" && isAncestorOrEqual(path, of: root) {
            if allowedInside.contains(where: { isAncestorOrEqual($0, of: path) }) { continue }
            return "contains protected location \(root)"
        }
        return nil
    }
}
```

`Packages/OpenCleanKit/Sources/RuleKit/GlobMatcher.swift`:

```swift
import Darwin
import Foundation

public struct GlobResult: Sendable, Equatable {
    public var matches: [String]
    public var errors: [String]
}

/// Matches absolute glob patterns component by component.
/// `*`, `?` and `[...]` match within one component (including dot-files); `**` matches zero or
/// more directory levels. Symlinked directories are never traversed; a symlink that matches the
/// final component is returned so the scanner can reject it.
public struct GlobMatcher: Sendable {
    public init() {}

    public static func hasWildcard(_ component: some StringProtocol) -> Bool {
        component.contains { $0 == "*" || $0 == "?" || $0 == "[" }
    }

    public static func literalPrefix(of pattern: String) -> String {
        let components = pattern.split(separator: "/")
        let literal = components.prefix { !hasWildcard($0) }
        return "/" + literal.joined(separator: "/")
    }

    public func match(_ pattern: String) -> GlobResult {
        precondition(pattern.hasPrefix("/"), "glob patterns must be absolute")
        let components = pattern.split(separator: "/").map(String.init)
        let literalCount = components.prefix { !Self.hasWildcard($0) }.count
        let base = "/" + components.prefix(literalCount).joined(separator: "/")
        let rest = components.dropFirst(literalCount)

        var result = GlobResult(matches: [], errors: [])
        if rest.isEmpty {
            if FileStat.of(base) != nil { result.matches = [base] }
            return result
        }
        guard let baseStat = FileStat.of(base), baseStat.isDirectory else { return result }
        var seen = Set<String>()
        walk(directory: base, components: rest, result: &result, seen: &seen)
        return result
    }

    private func walk(
        directory: String, components: ArraySlice<String>,
        result: inout GlobResult, seen: inout Set<String>
    ) {
        guard let component = components.first else { return }
        let remaining = components.dropFirst()

        if component == "**" {
            guard !remaining.isEmpty else { return }
            walk(directory: directory, components: remaining, result: &result, seen: &seen)
            for child in children(of: directory, errors: &result.errors) {
                let childPath = join(directory, child)
                if FileStat.of(childPath)?.isDirectory == true {
                    walk(directory: childPath, components: components, result: &result, seen: &seen)
                }
            }
            return
        }

        for child in children(of: directory, errors: &result.errors) where fnmatch(component, child, 0) == 0 {
            let childPath = join(directory, child)
            if remaining.isEmpty {
                if seen.insert(childPath).inserted { result.matches.append(childPath) }
            } else if FileStat.of(childPath)?.isDirectory == true {
                walk(directory: childPath, components: remaining, result: &result, seen: &seen)
            }
        }
    }

    private func children(of directory: String, errors: inout [String]) -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        } catch {
            errors.append("\(directory): \(error.localizedDescription)")
            return []
        }
    }

    private func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RuleKitTests`
Expected: PASS — all RuleKit tests including 35 parameterized deny/allow cases.

- [ ] **Step 5: Commit**

```bash
git add Packages
git commit -m "feat(rulekit): add deny-list, path expansion and glob matcher" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Rule linter and app paths

**Files:**
- Create: `Packages/OpenCleanKit/Sources/RuleKit/RuleLinter.swift`
- Create: `Packages/OpenCleanKit/Sources/RuleKit/AppPaths.swift`
- Test: `Packages/OpenCleanKit/Tests/RuleKitTests/RuleLinterTests.swift`

**Interfaces:**
- Consumes: Task 1 `Rule`, `RulePack`; Task 2 `DenyList`, `PathExpander`, `GlobMatcher.literalPrefix`.
- Produces:
  - `struct LintIssue: Equatable, CustomStringConvertible { pack: String; ruleID: String?; message: String }`
  - `struct RuleLinter { init(home: String, knownProbes: Set<String>); lint(_ packs: [RulePack]) -> [LintIssue]; lint(_ rule: Rule, pack: String) -> [LintIssue] }`
  - `struct AppPaths { support: URL; quarantine: URL; userRules: URL; settingsFile: URL; init(support:); static func standard(home:) -> AppPaths }`

- [ ] **Step 1: Write the failing tests**

`Packages/OpenCleanKit/Tests/RuleKitTests/RuleLinterTests.swift`:

```swift
import Foundation
import Testing
@testable import RuleKit

struct RuleLinterTests {
    let linter = RuleLinter(home: "/Users/tester", knownProbes: ["xcode.simulators"])

    func rule(
        id: String = "user.logs", paths: [String] = ["~/Library/Logs/*"], probe: String? = nil,
        safety: SafetyLevel = .regenerable, deleteMode: DeleteMode? = nil,
        requires: [Requirement] = [], minAgeDays: Int? = nil, explain: String = "Apps recreate them."
    ) -> Rule {
        Rule(
            id: id, name: "Name", category: .user, explain: explain, paths: paths, probe: probe,
            safety: safety, deleteMode: deleteMode, conditions: RuleConditions(minAgeDays: minAgeDays),
            requires: requires)
    }

    func messages(_ r: Rule) -> [String] { linter.lint(r, pack: "p").map(\.message) }

    @Test func validRuleHasNoIssues() {
        #expect(messages(rule()).isEmpty)
        #expect(messages(rule(paths: [], probe: "xcode.simulators", safety: .review)).isEmpty)
        #expect(messages(rule(paths: ["/Library/Caches/*"], requires: [.admin])).isEmpty)
    }

    @Test func rejectsBadIDs() {
        #expect(messages(rule(id: "Xcode Derived")).contains { $0.hasPrefix("id must be") })
        #expect(messages(rule(id: "xcode..data")).contains { $0.hasPrefix("id must be") })
    }

    @Test func requiresExplanation() {
        #expect(messages(rule(explain: "  ")).contains { $0.hasPrefix("explain is empty") })
    }

    @Test func requiresExactlyOneOfPathsOrProbe() {
        #expect(messages(rule(paths: [])).contains("needs either paths or probe"))
        #expect(messages(rule(probe: "xcode.simulators")).contains("use paths or probe, not both"))
        #expect(messages(rule(paths: [], probe: "nope")).contains("unknown probe nope"))
    }

    @Test(arguments: ["~/Documents/*", "~/*", "/System/Library/Caches/*", "~/Library/*", "/Applications/*", "*/x"])
    func rejectsProtectedOrRelativePaths(pattern: String) {
        #expect(!messages(rule(paths: [pattern])).isEmpty, "expected \(pattern) to be rejected")
    }

    @Test func rejectsTrailingDoubleStar() {
        #expect(messages(rule(paths: ["~/Library/Caches/**"])).contains { $0.hasPrefix("trailing ** is not supported") })
    }

    @Test func adminOnlyForRegenerableImmediateRules() {
        #expect(messages(rule(safety: .review, requires: [.admin])).contains {
            $0 == "requires: admin is only allowed for regenerable rules"
        })
        #expect(messages(rule(deleteMode: .quarantine, requires: [.admin])).contains {
            $0 == "requires: admin rules must delete immediately"
        })
    }

    @Test func rejectsNegativeAge() {
        #expect(messages(rule(minAgeDays: -1)).contains("min_age_days must be >= 0"))
    }

    @Test func detectsDuplicateIDsAcrossPacks() {
        let a = RulePack(pack: "a", rules: [rule(id: "x.y")])
        let b = RulePack(pack: "b", rules: [rule(id: "x.y")])
        let issues = linter.lint([a, b])
        #expect(issues == [LintIssue(pack: "b", ruleID: "x.y", message: "duplicate rule id")])
    }

    @Test func appPathsLiveInApplicationSupport() {
        let paths = AppPaths.standard(home: "/Users/tester")
        #expect(paths.support.path == "/Users/tester/Library/Application Support/OpenClean")
        #expect(paths.quarantine.path == "/Users/tester/Library/Application Support/OpenClean/Quarantine")
        #expect(paths.userRules.path == "/Users/tester/Library/Application Support/OpenClean/rules")
        #expect(paths.settingsFile.lastPathComponent == "settings.json")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RuleKitTests`
Expected: build FAILS — `cannot find 'RuleLinter' in scope`, `cannot find 'AppPaths' in scope`.

- [ ] **Step 3: Implement**

`Packages/OpenCleanKit/Sources/RuleKit/RuleLinter.swift`:

```swift
import Foundation

public struct LintIssue: Sendable, Equatable, CustomStringConvertible {
    public let pack: String
    public let ruleID: String?
    public let message: String

    public init(pack: String, ruleID: String?, message: String) {
        self.pack = pack
        self.ruleID = ruleID
        self.message = message
    }

    public var description: String {
        "\(pack)\(ruleID.map { " [\($0)]" } ?? ""): \(message)"
    }
}

/// Validates rule packs beyond what the YAML schema can express.
public struct RuleLinter: Sendable {
    public let denyList: DenyList
    public let expander: PathExpander
    public let knownProbes: Set<String>

    public init(home: String, knownProbes: Set<String>) {
        denyList = DenyList(home: home)
        expander = PathExpander(home: home)
        self.knownProbes = knownProbes
    }

    public func lint(_ packs: [RulePack]) -> [LintIssue] {
        var seen = Set<String>()
        var issues: [LintIssue] = []
        for pack in packs {
            for rule in pack.rules {
                issues += lint(rule, pack: pack.pack)
                if !seen.insert(rule.id).inserted {
                    issues.append(LintIssue(pack: pack.pack, ruleID: rule.id, message: "duplicate rule id"))
                }
            }
        }
        return issues
    }

    public func lint(_ rule: Rule, pack: String) -> [LintIssue] {
        var problems: [String] = []

        if rule.id.range(of: #"^[a-z0-9]+([.-][a-z0-9]+)*$"#, options: .regularExpression) == nil {
            problems.append("id must be lowercase words separated by . or - (e.g. xcode.derived-data)")
        }
        if rule.name.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("name is empty")
        }
        if rule.explain.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("explain is empty: say why removing this is safe")
        }

        switch (rule.paths.isEmpty, rule.probe) {
        case (true, nil):
            problems.append("needs either paths or probe")
        case (false, .some):
            problems.append("use paths or probe, not both")
        case (true, .some(let probe)) where !knownProbes.contains(probe):
            problems.append("unknown probe \(probe)")
        default:
            break
        }

        for pattern in rule.paths {
            guard pattern.hasPrefix("/") || pattern.hasPrefix("~/") else {
                problems.append("path must start with / or ~/: \(pattern)")
                continue
            }
            if pattern.hasSuffix("/**") {
                problems.append("trailing ** is not supported; use * to match entries: \(pattern)")
            }
            let prefix = GlobMatcher.literalPrefix(of: expander.expand(pattern))
            if let reason = denyList.denialReason(for: prefix) {
                problems.append("path \(pattern) is in a protected location (\(reason))")
            }
        }

        if rule.needs(.admin) {
            if rule.safety != .regenerable {
                problems.append("requires: admin is only allowed for regenerable rules")
            }
            if rule.effectiveDeleteMode != .immediate {
                problems.append("requires: admin rules must delete immediately")
            }
        }
        if let days = rule.conditions.minAgeDays, days < 0 {
            problems.append("min_age_days must be >= 0")
        }

        return problems.map { LintIssue(pack: pack, ruleID: rule.id, message: $0) }
    }
}
```

`Packages/OpenCleanKit/Sources/RuleKit/AppPaths.swift`:

```swift
import Foundation

/// OpenClean's on-disk locations, rooted in `~/Library/Application Support/OpenClean`.
public struct AppPaths: Sendable, Equatable {
    public let support: URL

    public init(support: URL) {
        self.support = support
    }

    public static func standard(home: String) -> AppPaths {
        AppPaths(
            support: URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("Library/Application Support/OpenClean", isDirectory: true))
    }

    public var quarantine: URL { support.appendingPathComponent("Quarantine", isDirectory: true) }
    public var userRules: URL { support.appendingPathComponent("rules", isDirectory: true) }
    public var settingsFile: URL { support.appendingPathComponent("settings.json") }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RuleKitTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages
git commit -m "feat(rulekit): add rule linter and app paths" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 4: Scan models, sizing and the path-rule scanner

**Files:**
- Modify: `Package.swift` (add `ScanEngine`, `ScanEngineTests`; give `TestSupport` a `ScanEngine` dependency)
- Create: `Packages/OpenCleanKit/Sources/ScanEngine/Models.swift`
- Create: `Packages/OpenCleanKit/Sources/ScanEngine/ProcessChecker.swift`
- Create: `Packages/OpenCleanKit/Sources/ScanEngine/FileSizer.swift`
- Create: `Packages/OpenCleanKit/Sources/ScanEngine/ItemBuilder.swift`
- Create: `Packages/OpenCleanKit/Sources/ScanEngine/PathRuleScanner.swift`
- Create: `Packages/OpenCleanKit/Sources/TestSupport/FakeProcessChecker.swift`
- Modify: `docs/superpowers/specs/2026-10-12-openclean-core-cleanup-design.md` (sections 4 "Hard deny-list" and "Path resolution")
- Test: `Packages/OpenCleanKit/Tests/ScanEngineTests/PathRuleScannerTests.swift`

**Interfaces:**
- Consumes: Task 1 `Rule`, `RuleConditions`, `Requirement`; Task 2 `FileStat`, `realPath`, `PathExpander`, `DenyList`, `GlobMatcher`.
- Produces:
  - `struct ScanItem: Hashable, Identifiable { path, ruleID, size: Int64, device: Int32, inode: UInt64, modificationDate: Date, ownerUID: UInt32, reportOnly: Bool, hint: String? }` with `static func virtual(path:ruleID:hint:) -> ScanItem` and `static func snapshot(of:ruleID:) -> ScanItem?`
  - `enum RuleScanStatus: Equatable { scanned, needsFullDiskAccess, skippedAppRunning(String), cancelled }`
  - `struct RuleResult: Identifiable { rule: Rule; items: [ScanItem]; status; errors: [String]; totalSize: Int64 (removable only); reportOnlySize: Int64; init(rule:items:status:errors:) }`
  - `struct ScanResult { rules: [RuleResult]; isComplete: Bool; startedAt: Date; finishedAt: Date; totalSize: Int64; allItems: [ScanItem]; categories: [(category: RuleCategory, rules: [RuleResult])]; rule(_ id: String) -> RuleResult? }`
  - `struct ScanProgress: Equatable { ruleID: String; finished: Int; total: Int; fraction: Double }`
  - `protocol ProcessChecker: Sendable { func isRunning(bundleID: String) -> Bool }`, `struct RunningProcessChecker: ProcessChecker`
  - `struct ScanContext { home, hasFullDiskAccess, processChecker, userExcludes: [String], now: Date; expander; denyList }`
  - `final class HardLinkLedger`, `enum FileSizer { static func allocatedSize(of:ledger:) -> Int64 }`
  - `struct PathRuleScanner { scan(_ rule: Rule, context: ScanContext, ledger: HardLinkLedger) -> RuleResult }`
  - internal `enum Gate`, `enum ItemBuilder` (used by Task 5)
  - `struct FakeProcessChecker: ProcessChecker { init(running: Set<String>) }` (TestSupport)

- [ ] **Step 1: Add the targets**

In `Package.swift`, replace the `TestSupport` target and append the new targets so `targets:` contains:

```swift
        .target(
            name: "TestSupport",
            dependencies: ["ScanEngine"],
            path: "Packages/OpenCleanKit/Sources/TestSupport"
        ),
        .target(
            name: "RuleKit",
            dependencies: [.product(name: "Yams", package: "Yams")],
            path: "Packages/OpenCleanKit/Sources/RuleKit"
        ),
        .target(
            name: "ScanEngine",
            dependencies: ["RuleKit"],
            path: "Packages/OpenCleanKit/Sources/ScanEngine"
        ),
        .testTarget(
            name: "RuleKitTests",
            dependencies: ["RuleKit", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/RuleKitTests"
        ),
        .testTarget(
            name: "ScanEngineTests",
            dependencies: ["ScanEngine", "RuleKit", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/ScanEngineTests"
        ),
```

- [ ] **Step 2: Write the failing tests**

`Packages/OpenCleanKit/Tests/ScanEngineTests/PathRuleScannerTests.swift`:

```swift
import Foundation
import RuleKit
import Testing
import TestSupport
@testable import ScanEngine

struct PathRuleScannerTests {
    func context(
        _ home: TempDirectory, fda: Bool = true, running: Set<String> = [],
        excludes: [String] = [], now: Date = .now
    ) -> ScanContext {
        ScanContext(
            home: home.path, hasFullDiskAccess: fda, processChecker: FakeProcessChecker(running: running),
            userExcludes: excludes, now: now)
    }

    func rule(
        _ paths: [String], exclude: [String] = [], conditions: RuleConditions = RuleConditions(),
        requires: [Requirement] = []
    ) -> Rule {
        Rule(
            id: "test.rule", name: "Test", category: .user, explain: "x", paths: paths,
            safety: .regenerable, conditions: conditions, exclude: exclude, requires: requires)
    }

    func scan(_ rule: Rule, _ context: ScanContext) -> RuleResult {
        PathRuleScanner().scan(rule, context: context, ledger: HardLinkLedger())
    }

    @Test func matchesEntriesWithAllocatedSizesLargestFirst() throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/small/f", bytes: 4_096)
        try home.file("Library/Caches/big/f", bytes: 65_536)
        let result = scan(rule(["~/Library/Caches/*"]), context(home))
        #expect(result.status == .scanned)
        #expect(result.items.map(\.path) == [home.path + "/Library/Caches/big", home.path + "/Library/Caches/small"])
        #expect(result.items[0].size >= 65_536)
        #expect(result.items[1].size >= 4_096)
        #expect(result.items.allSatisfy { $0.ruleID == "test.rule" && !$0.reportOnly })
    }

    @Test func appliesRuleExcludes() throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/keep/f", bytes: 10)
        try home.file("Library/Caches/skip-me/f", bytes: 10)
        try home.file("Library/Caches/clean/f", bytes: 10)
        let r = rule(["~/Library/Caches/*"], exclude: ["~/Library/Caches/keep", "*/skip-*"])
        #expect(scan(r, context(home)).items.map(\.path) == [home.path + "/Library/Caches/clean"])
    }

    @Test func dropsSymlinkThatEscapesIntoDocuments() throws {
        let home = try TempDirectory()
        try home.file("Documents/secret.txt", bytes: 10)
        try home.directory("Library/Caches")
        try home.symlink("Library/Caches/evil", to: home.path + "/Documents")
        let result = scan(rule(["~/Library/Caches/*"]), context(home))
        #expect(result.items.isEmpty)
        #expect(result.errors.contains { $0.contains("symbolic link skipped") })
    }

    @Test func dropsProtectedMatches() throws {
        let home = try TempDirectory()
        try home.file("Documents/a", bytes: 10)
        try home.file("Desktop/b", bytes: 10)
        try home.file("junk/c", bytes: 10)
        let result = scan(rule(["~/*"]), context(home))
        #expect(result.items.map(\.path) == [home.path + "/junk"])
        #expect(result.errors.filter { $0.contains("protected") }.count == 2)
    }

    @Test func honoursMinimumAge() throws {
        let home = try TempDirectory()
        let now = Date()
        try home.file("Library/Logs/old.log", bytes: 10, modified: now.addingTimeInterval(-10 * 86_400))
        try home.file("Library/Logs/new.log", bytes: 10, modified: now)
        let r = rule(["~/Library/Logs/*"], conditions: RuleConditions(minAgeDays: 5))
        #expect(scan(r, context(home, now: now)).items.map(\.path) == [home.path + "/Library/Logs/old.log"])
    }

    @Test func honoursMinimumSize() throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/tiny", bytes: 1_000)
        try home.file("Library/Caches/huge", bytes: 100_000)
        let r = rule(["~/Library/Caches/*"], conditions: RuleConditions(minSize: ByteSize(bytes: 50_000)))
        #expect(scan(r, context(home)).items.map(\.path) == [home.path + "/Library/Caches/huge"])
    }

    @Test func requiresFullDiskAccessWhenDeclared() throws {
        let home = try TempDirectory()
        try home.file(".Trash/x", bytes: 10)
        let result = scan(rule(["~/.Trash/*"], requires: [.fullDiskAccess]), context(home, fda: false))
        #expect(result.status == .needsFullDiskAccess)
        #expect(result.items.isEmpty)
    }

    @Test func skipsWhileAppRunning() throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/x", bytes: 10)
        let r = rule(["~/Library/Caches/*"], conditions: RuleConditions(appNotRunning: ["com.example.app"]))
        let result = scan(r, context(home, running: ["com.example.app"]))
        #expect(result.status == .skippedAppRunning("com.example.app"))
        #expect(result.items.isEmpty)
    }

    @Test func countsHardLinkedFilesOnce() throws {
        let home = try TempDirectory()
        let original = try home.file("Library/Caches/a/data", bytes: 262_144)
        try home.directory("Library/Caches/b")
        try FileManager.default.linkItem(atPath: original, toPath: home.path + "/Library/Caches/b/data")
        let result = scan(rule(["~/Library/Caches/*"]), context(home))
        #expect(result.items.count == 2)
        #expect(result.totalSize >= 262_144)
        #expect(result.totalSize < 2 * 262_144)
    }

    @Test func sparseFilesCountOnlyAllocatedBlocks() throws {
        let home = try TempDirectory()
        let path = try home.file("Library/Caches/sparse.img")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seek(toOffset: 100_000_000)
        try handle.write(contentsOf: Data([1]))
        try handle.close()
        let result = scan(rule(["~/Library/Caches/*"]), context(home))
        #expect(try #require(result.items.first).size < 1_000_000)
    }

    @Test func honoursUserExcludedPaths() throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/mine/f", bytes: 10)
        try home.file("Library/Caches/other/f", bytes: 10)
        let result = scan(rule(["~/Library/Caches/*"]), context(home, excludes: [home.path + "/Library/Caches/mine"]))
        #expect(result.items.map(\.path) == [home.path + "/Library/Caches/other"])
    }

    @Test func snapshotMatchesScannerFields() throws {
        let home = try TempDirectory()
        let path = try home.file("f", bytes: 8_192)
        let item = try #require(ScanItem.snapshot(of: path, ruleID: "r"))
        let stat = try #require(FileStat.of(path))
        #expect(item.inode == stat.inode)
        #expect(item.modificationDate == stat.modificationDate)
        #expect(item.size >= 8_192)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter ScanEngineTests`
Expected: build FAILS — `no such module 'ScanEngine'` or `cannot find 'ScanContext' in scope`.

- [ ] **Step 4: Implement**

`Packages/OpenCleanKit/Sources/ScanEngine/Models.swift`:

```swift
import Foundation
import RuleKit

/// One removable entry found by a rule: a file or a directory (removed as a whole).
public struct ScanItem: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let ruleID: String
    public let size: Int64
    public let device: Int32
    public let inode: UInt64
    public let modificationDate: Date
    public let ownerUID: UInt32
    /// Shown with size and hint, but never selectable or removable.
    public let reportOnly: Bool
    public let hint: String?

    public init(
        path: String, ruleID: String, size: Int64, device: Int32, inode: UInt64,
        modificationDate: Date, ownerUID: UInt32, reportOnly: Bool = false, hint: String? = nil
    ) {
        self.path = path
        self.ruleID = ruleID
        self.size = size
        self.device = device
        self.inode = inode
        self.modificationDate = modificationDate
        self.ownerUID = ownerUID
        self.reportOnly = reportOnly
        self.hint = hint
    }

    /// A report-only entry that is not a filesystem path (e.g. a Time Machine snapshot).
    public static func virtual(path: String, ruleID: String, hint: String?) -> ScanItem {
        ScanItem(
            path: path, ruleID: ruleID, size: 0, device: 0, inode: 0,
            modificationDate: .distantPast, ownerUID: 0, reportOnly: true, hint: hint)
    }

    /// A fresh snapshot of an existing path, recorded the same way the scanner does.
    public static func snapshot(of path: String, ruleID: String) -> ScanItem? {
        guard let stat = FileStat.of(path) else { return nil }
        return ScanItem(
            path: path, ruleID: ruleID, size: FileSizer.allocatedSize(of: path, ledger: HardLinkLedger()),
            device: stat.device, inode: stat.inode, modificationDate: stat.modificationDate,
            ownerUID: stat.ownerUID)
    }
}

public enum RuleScanStatus: Sendable, Equatable {
    case scanned
    case needsFullDiskAccess
    case skippedAppRunning(String)
    case cancelled
}

public struct RuleResult: Sendable, Identifiable {
    public var id: String { rule.id }
    public let rule: Rule
    public var items: [ScanItem]
    public var status: RuleScanStatus
    public var errors: [String]

    public init(rule: Rule, items: [ScanItem] = [], status: RuleScanStatus = .scanned, errors: [String] = []) {
        self.rule = rule
        self.items = items
        self.status = status
        self.errors = errors
    }

    /// Bytes that can actually be removed (report-only items excluded).
    public var totalSize: Int64 { items.filter { !$0.reportOnly }.reduce(0) { $0 + $1.size } }
    /// Bytes shown for information only (e.g. Docker's disk image).
    public var reportOnlySize: Int64 { items.filter(\.reportOnly).reduce(0) { $0 + $1.size } }
}

public struct ScanResult: Sendable {
    public var rules: [RuleResult]
    public var isComplete: Bool
    public var startedAt: Date
    public var finishedAt: Date

    public init(rules: [RuleResult], isComplete: Bool, startedAt: Date, finishedAt: Date) {
        self.rules = rules
        self.isComplete = isComplete
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var totalSize: Int64 { rules.reduce(0) { $0 + $1.totalSize } }
    public var allItems: [ScanItem] { rules.flatMap(\.items) }
    public func rule(_ id: String) -> RuleResult? { rules.first { $0.rule.id == id } }

    /// Rule results grouped by category in `RuleCategory.allCases` order; empty categories omitted.
    public var categories: [(category: RuleCategory, rules: [RuleResult])] {
        RuleCategory.allCases.compactMap { category in
            let matching = rules.filter { $0.rule.category == category }
            return matching.isEmpty ? nil : (category, matching)
        }
    }
}

public struct ScanProgress: Sendable, Equatable {
    public let ruleID: String
    public let finished: Int
    public let total: Int

    public init(ruleID: String, finished: Int, total: Int) {
        self.ruleID = ruleID
        self.finished = finished
        self.total = total
    }

    public var fraction: Double { total == 0 ? 1 : Double(finished) / Double(total) }
}

/// Everything a scan needs from the outside world. `home` is injected so tests never touch the real one.
public struct ScanContext: Sendable {
    public var home: String
    public var hasFullDiskAccess: Bool
    public var processChecker: any ProcessChecker
    /// Absolute paths the user excluded in Settings; items equal to or inside them are skipped.
    public var userExcludes: [String]
    public var now: Date

    public init(
        home: String, hasFullDiskAccess: Bool, processChecker: any ProcessChecker,
        userExcludes: [String] = [], now: Date = .now
    ) {
        self.home = home
        self.hasFullDiskAccess = hasFullDiskAccess
        self.processChecker = processChecker
        self.userExcludes = userExcludes
        self.now = now
    }

    public var expander: PathExpander { PathExpander(home: home) }
    public var denyList: DenyList { DenyList(home: home) }
}
```

`Packages/OpenCleanKit/Sources/ScanEngine/ProcessChecker.swift`:

```swift
import Darwin
import Foundation

public protocol ProcessChecker: Sendable {
    func isRunning(bundleID: String) -> Bool
}

/// Finds running apps by walking the process table and reading each process's enclosing
/// `.app` bundle identifier. Pure Darwin + Foundation, safe off the main thread.
public struct RunningProcessChecker: ProcessChecker {
    public init() {}

    public func isRunning(bundleID: String) -> Bool {
        Self.runningBundleIDs().contains(bundleID)
    }

    public static func runningBundleIDs() -> Set<String> {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        var bundlePaths = Set<String>()
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            guard let range = path.range(of: ".app/", options: .backwards) else { continue }
            bundlePaths.insert(String(path[..<range.upperBound].dropLast()))
        }
        return Set(bundlePaths.compactMap { Bundle(path: $0)?.bundleIdentifier })
    }
}
```

`Packages/OpenCleanKit/Sources/ScanEngine/FileSizer.swift`:

```swift
import Foundation
import RuleKit
import os

/// Remembers multiply-linked files so each is counted once per scan.
public final class HardLinkLedger: Sendable {
    private struct Key: Hashable, Sendable {
        let device: Int32
        let inode: UInt64
    }

    private let claimed = OSAllocatedUnfairLock(initialState: Set<Key>())

    public init() {}

    /// True the first time a given (device, inode) is claimed.
    public func claim(device: Int32, inode: UInt64) -> Bool {
        claimed.withLock { $0.insert(Key(device: device, inode: inode)).inserted }
    }
}

public enum FileSizer {
    /// Allocated bytes of a file, or of a directory tree without following symlinks.
    /// Hard-linked files count once per ledger. Stops early if the task is cancelled.
    public static func allocatedSize(of path: String, ledger: HardLinkLedger) -> Int64 {
        guard let root = FileStat.of(path) else { return 0 }
        var total = countable(root, ledger)
        guard root.isDirectory, let enumerator = FileManager.default.enumerator(atPath: path) else {
            return total
        }
        while let relative = enumerator.nextObject() as? String {
            if Task.isCancelled { break }
            if let stat = FileStat.of(path + "/" + relative) {
                total += countable(stat, ledger)
            }
        }
        return total
    }

    private static func countable(_ stat: FileStat, _ ledger: HardLinkLedger) -> Int64 {
        if !stat.isDirectory, stat.linkCount > 1, !ledger.claim(device: stat.device, inode: stat.inode) {
            return 0
        }
        return stat.allocatedBytes
    }
}
```

`Packages/OpenCleanKit/Sources/ScanEngine/ItemBuilder.swift`:

```swift
import Foundation
import RuleKit

/// Checks that apply before a rule is scanned at all.
enum Gate {
    static func check(_ rule: Rule, _ context: ScanContext) -> RuleScanStatus? {
        if rule.needs(.fullDiskAccess) && !context.hasFullDiskAccess {
            return .needsFullDiskAccess
        }
        if let running = rule.conditions.appNotRunning.first(where: { context.processChecker.isRunning(bundleID: $0) }) {
            return .skippedAppRunning(running)
        }
        return nil
    }
}

enum BuildOutcome {
    case item(ScanItem)
    case dropped(String)
    case filtered
}

/// Turns a candidate path into a `ScanItem`, applying resolution, deny-list and conditions.
enum ItemBuilder {
    static func build(
        path: String, within prefixReal: String?, rule: Rule, context: ScanContext,
        ledger: HardLinkLedger, reportOnly: Bool = false, hint: String? = nil
    ) -> BuildOutcome {
        guard let stat = FileStat.of(path) else { return .dropped("disappeared during scan") }
        if stat.isSymlink { return .dropped("symbolic link skipped") }
        guard let real = realPath(path) else { return .dropped("cannot resolve path") }
        if let prefixReal, real != prefixReal, !real.hasPrefix(prefixReal == "/" ? "/" : prefixReal + "/") {
            return .dropped("resolves outside \(prefixReal)")
        }
        if let reason = context.denyList.denialReason(for: real) {
            return .dropped("protected: \(reason)")
        }
        if context.userExcludes.contains(where: { real == $0 || real.hasPrefix($0 + "/") }) {
            return .filtered
        }
        if let days = rule.conditions.minAgeDays,
            stat.modificationDate > context.now.addingTimeInterval(-Double(days) * 86_400)
        {
            return .filtered
        }
        let size = FileSizer.allocatedSize(of: real, ledger: ledger)
        if let minimum = rule.conditions.minSize, size < minimum.bytes {
            return .filtered
        }
        return .item(
            ScanItem(
                path: real, ruleID: rule.id, size: size, device: stat.device, inode: stat.inode,
                modificationDate: stat.modificationDate, ownerUID: stat.ownerUID,
                reportOnly: reportOnly, hint: hint))
    }
}
```

`Packages/OpenCleanKit/Sources/ScanEngine/PathRuleScanner.swift`:

```swift
import Darwin
import Foundation
import RuleKit

/// Scans a rule that lists `paths`. Synchronous; checks task cancellation between matches.
public struct PathRuleScanner: Sendable {
    public init() {}

    public func scan(_ rule: Rule, context: ScanContext, ledger: HardLinkLedger) -> RuleResult {
        var result = RuleResult(rule: rule)
        if let blocked = Gate.check(rule, context) {
            result.status = blocked
            return result
        }
        let expander = context.expander
        let excludes = rule.exclude.map(expander.expand)

        patterns: for pattern in rule.paths {
            if Task.isCancelled {
                result.status = .cancelled
                break
            }
            let expanded = expander.expand(pattern)
            guard let prefixReal = realPath(GlobMatcher.literalPrefix(of: expanded)) else { continue }
            let glob = GlobMatcher().match(expanded)
            result.errors += glob.errors
            for match in glob.matches {
                if Task.isCancelled {
                    result.status = .cancelled
                    break patterns
                }
                if excludes.contains(where: { fnmatch($0, match, 0) == 0 }) { continue }
                switch ItemBuilder.build(path: match, within: prefixReal, rule: rule, context: context, ledger: ledger) {
                case .item(let item): result.items.append(item)
                case .dropped(let reason): result.errors.append("\(match): \(reason)")
                case .filtered: break
                }
            }
        }
        result.items.sort { $0.size > $1.size }
        return result
    }
}
```

`Packages/OpenCleanKit/Sources/TestSupport/FakeProcessChecker.swift`:

```swift
import ScanEngine

public struct FakeProcessChecker: ProcessChecker {
    public let running: Set<String>

    public init(running: Set<String> = []) {
        self.running = running
    }

    public func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ScanEngineTests`
Expected: PASS — 12 tests.

- [ ] **Step 6: Record the sizing and deny-list clarifications in the spec**

In `docs/superpowers/specs/2026-10-12-openclean-core-cleanup-design.md`, section 4:

Replace the sentence
`- Sizes use allocated size (`totalFileAllocatedSize`), so APFS clones and sparse files do not inflate freed-space numbers. Hard-linked files are counted once per scan (deduplicated by inode).`
with
`- Sizes use allocated blocks (`st_blocks`), so sparse files do not inflate freed-space numbers. Hard-linked files are counted once per scan (deduplicated by device + inode). APFS clones are counted at full allocation: macOS has no public API for shared-block accounting, so freed space may be overstated for cloned files.`

Replace the sentence
`Rules whose glob literal prefix falls in the deny-list fail lint. At scan time, every resolved match is re-checked.`
with
`A path is also denied when it contains a protected location (for example `~/Library`, `/Library`, `/Users`), and `~/Library/Mobile Documents` is protected as a whole subtree. Rules whose glob literal prefix falls in the deny-list fail lint. At scan time, every resolved match is re-checked.`

- [ ] **Step 7: Commit**

```bash
git add Package.swift Packages docs/superpowers/specs
git commit -m "feat(scan): add scan models, sizing and path-rule scanner" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Probe protocol and the concurrent scan engine

**Files:**
- Create: `Packages/OpenCleanKit/Sources/ScanEngine/Probe.swift`
- Create: `Packages/OpenCleanKit/Sources/ScanEngine/ScanEngine.swift`
- Test: `Packages/OpenCleanKit/Tests/ScanEngineTests/ScanEngineTests.swift`

**Interfaces:**
- Consumes: Task 4 `ScanItem`, `RuleResult`, `ScanResult`, `ScanProgress`, `ScanContext`, `HardLinkLedger`, `PathRuleScanner`, `Gate`, `ItemBuilder`, `FileStat`.
- Produces:
  - `struct ProbeFinding: Equatable { path: String; reportOnly: Bool; hint: String?; init(path:reportOnly:hint:) }`
  - `protocol Probe: Sendable { static var id: String { get }; func scan(_ context: ScanContext) async throws -> [ProbeFinding] }`
  - `struct ProbeRegistry { init(_ probes: [any Probe]); ids: Set<String>; probe(for id: String) -> (any Probe)? }`
  - `struct ScanEngine { init(registry: ProbeRegistry = ProbeRegistry([])); scan(_ rules: [Rule], context: ScanContext, progress: AsyncStream<ScanProgress>.Continuation? = nil) async -> ScanResult }` — finishes `progress` when done.

- [ ] **Step 1: Write the failing tests**

`Packages/OpenCleanKit/Tests/ScanEngineTests/ScanEngineTests.swift`:

```swift
import Foundation
import RuleKit
import Testing
import TestSupport
@testable import ScanEngine

struct StubProbe: Probe {
    static let id = "stub.probe"
    let findings: [ProbeFinding]
    func scan(_ context: ScanContext) async throws -> [ProbeFinding] { findings }
}

struct SlowProbe: Probe {
    static let id = "slow.probe"
    func scan(_ context: ScanContext) async throws -> [ProbeFinding] {
        try await Task.sleep(for: .seconds(30))
        return []
    }
}

struct ScanEngineTests {
    func context(_ home: TempDirectory) -> ScanContext {
        ScanContext(home: home.path, hasFullDiskAccess: true, processChecker: FakeProcessChecker())
    }

    func pathRule(_ id: String, _ paths: [String]) -> Rule {
        Rule(id: id, name: id, category: .user, explain: "x", paths: paths, safety: .regenerable)
    }

    func probeRule(_ id: String, probe: String) -> Rule {
        Rule(id: id, name: id, category: .developer, explain: "x", probe: probe, safety: .review)
    }

    @Test func returnsResultsInRuleOrderAndReportsProgress() async throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/a/f", bytes: 10)
        try home.file("Library/Logs/b.log", bytes: 10)
        let rules = [
            pathRule("one", ["~/Library/Caches/*"]),
            pathRule("two", ["~/Library/Logs/*"]),
            pathRule("three", ["~/nothing/*"]),
        ]
        let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)
        let result = await ScanEngine().scan(rules, context: context(home), progress: continuation)
        var events: [ScanProgress] = []
        for await event in stream { events.append(event) }

        #expect(result.rules.map(\.rule.id) == ["one", "two", "three"])
        #expect(result.isComplete)
        #expect(events.count == 3)
        #expect(events.last?.finished == 3)
        #expect(events.last?.fraction == 1)
    }

    @Test func overlappingRulesCountEachFileOnce() async throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/Homebrew/bottle.tar", bytes: 8_192)
        try home.file("Library/Caches/other/f", bytes: 10)
        let rules = [
            pathRule("homebrew", ["~/Library/Caches/Homebrew/*"]),
            pathRule("caches", ["~/Library/Caches/*"]),
        ]
        let result = await ScanEngine().scan(rules, context: context(home))
        #expect(result.rule("homebrew")?.items.map(\.path) == [home.path + "/Library/Caches/Homebrew/bottle.tar"])
        #expect(result.rule("caches")?.items.map(\.path) == [home.path + "/Library/Caches/other"])
    }

    @Test func probeFindingsPassTheSameSafetyChecks() async throws {
        let home = try TempDirectory()
        let device = home.path + "/Library/Developer/CoreSimulator/Devices/ABC"
        try home.file("Library/Developer/CoreSimulator/Devices/ABC/data", bytes: 4_096)
        try home.file("Documents/x", bytes: 10)
        let probe = StubProbe(findings: [
            ProbeFinding(path: device, hint: "old"),
            ProbeFinding(path: home.path + "/Documents"),
            ProbeFinding(path: "tmsnapshot://com.apple.TimeMachine.1", reportOnly: true, hint: "snap"),
        ])
        let engine = ScanEngine(registry: ProbeRegistry([probe]))
        let result = await engine.scan([probeRule("sims", probe: StubProbe.id)], context: context(home))
        let items = try #require(result.rule("sims")).items
        #expect(Set(items.map(\.path)) == [device, "tmsnapshot://com.apple.TimeMachine.1"])
        #expect(items.first { $0.path == device }?.size ?? 0 >= 4_096)
        #expect(items.first { $0.path == device }?.hint == "old")
        #expect(items.first { $0.reportOnly }?.size == 0)
        #expect(result.rule("sims")?.errors.contains { $0.contains("protected") } == true)
    }

    @Test func unknownProbeIsReportedNotFatal() async throws {
        let home = try TempDirectory()
        let result = await ScanEngine().scan([probeRule("x", probe: "missing.probe")], context: context(home))
        #expect(result.rule("x")?.errors == ["unknown probe missing.probe"])
        #expect(result.isComplete)
    }

    @Test func cancellationReturnsIncompleteResult() async throws {
        let home = try TempDirectory()
        let engine = ScanEngine(registry: ProbeRegistry([SlowProbe()]))
        let rules = [probeRule("slow", probe: SlowProbe.id)]
        let ctx = context(home)
        let task = Task { await engine.scan(rules, context: ctx) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value
        #expect(!result.isComplete)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ScanEngineTests`
Expected: build FAILS — `cannot find type 'Probe' in scope`, `cannot find 'ScanEngine' in scope`.

- [ ] **Step 3: Implement**

`Packages/OpenCleanKit/Sources/ScanEngine/Probe.swift`:

```swift
import Foundation

/// A path (or, when report-only, a virtual identifier) found by a probe.
public struct ProbeFinding: Sendable, Equatable {
    public let path: String
    public let reportOnly: Bool
    public let hint: String?

    public init(path: String, reportOnly: Bool = false, hint: String? = nil) {
        self.path = path
        self.reportOnly = reportOnly
        self.hint = hint
    }
}

/// Swift logic for targets a glob cannot express. Probes only find; they never remove.
public protocol Probe: Sendable {
    static var id: String { get }
    func scan(_ context: ScanContext) async throws -> [ProbeFinding]
}

public struct ProbeRegistry: Sendable {
    private let probes: [String: any Probe]

    public init(_ probes: [any Probe]) {
        self.probes = Dictionary(probes.map { (type(of: $0).id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public var ids: Set<String> { Set(probes.keys) }

    public func probe(for id: String) -> (any Probe)? { probes[id] }
}
```

`Packages/OpenCleanKit/Sources/ScanEngine/ScanEngine.swift`:

```swift
import Foundation
import RuleKit

/// Runs every rule concurrently and returns results in the order the rules were given.
public struct ScanEngine: Sendable {
    public let registry: ProbeRegistry

    public init(registry: ProbeRegistry = ProbeRegistry([])) {
        self.registry = registry
    }

    /// Scans `rules`. Yields one progress event per finished rule and finishes `progress`.
    /// Cancelling the calling task returns partial results with `isComplete == false`.
    public func scan(
        _ rules: [Rule], context: ScanContext,
        progress: AsyncStream<ScanProgress>.Continuation? = nil
    ) async -> ScanResult {
        let started = Date()
        let ledger = HardLinkLedger()
        var slots = [RuleResult?](repeating: nil, count: rules.count)
        var finished = 0

        await withTaskGroup(of: (Int, RuleResult).self) { group in
            for (index, rule) in rules.enumerated() {
                group.addTask {
                    (index, await self.scanOne(rule, context: context, ledger: ledger))
                }
            }
            for await (index, result) in group {
                slots[index] = result
                finished += 1
                progress?.yield(ScanProgress(ruleID: result.rule.id, finished: finished, total: rules.count))
            }
        }
        progress?.finish()

        var results = slots.compactMap { $0 }
        Self.removeOverlaps(&results)
        let complete = !Task.isCancelled && !results.contains { $0.status == .cancelled }
        return ScanResult(rules: results, isComplete: complete, startedAt: started, finishedAt: Date())
    }

    func scanOne(_ rule: Rule, context: ScanContext, ledger: HardLinkLedger) async -> RuleResult {
        if Task.isCancelled { return RuleResult(rule: rule, status: .cancelled) }
        guard let probeID = rule.probe else {
            return PathRuleScanner().scan(rule, context: context, ledger: ledger)
        }

        var result = RuleResult(rule: rule)
        if let blocked = Gate.check(rule, context) {
            result.status = blocked
            return result
        }
        guard let probe = registry.probe(for: probeID) else {
            result.errors.append("unknown probe \(probeID)")
            return result
        }
        do {
            for finding in try await probe.scan(context) {
                if finding.reportOnly && FileStat.of(finding.path) == nil {
                    result.items.append(.virtual(path: finding.path, ruleID: rule.id, hint: finding.hint))
                    continue
                }
                switch ItemBuilder.build(
                    path: finding.path, within: nil, rule: rule, context: context, ledger: ledger,
                    reportOnly: finding.reportOnly, hint: finding.hint)
                {
                case .item(let item): result.items.append(item)
                case .dropped(let reason): result.errors.append("\(finding.path): \(reason)")
                case .filtered: break
                }
            }
        } catch {
            if Task.isCancelled { result.status = .cancelled }
            result.errors.append("probe \(probeID) failed: \(error)")
        }
        result.items.sort { $0.size > $1.size }
        return result
    }

    /// Keeps each path once: an item is dropped when an earlier rule already claimed it,
    /// one of its ancestors, or one of its descendants.
    static func removeOverlaps(_ results: inout [RuleResult]) {
        var claimed = Set<String>()
        var claimedAncestors = Set<String>()
        for index in results.indices {
            results[index].items = results[index].items.filter { item in
                if item.reportOnly { return true }
                let ancestors = ancestorPaths(of: item.path)
                if claimed.contains(item.path) || claimedAncestors.contains(item.path)
                    || ancestors.contains(where: claimed.contains)
                {
                    return false
                }
                claimed.insert(item.path)
                claimedAncestors.formUnion(ancestors)
                return true
            }
        }
    }

    static func ancestorPaths(of path: String) -> [String] {
        var result: [String] = []
        var current = (path as NSString).deletingLastPathComponent
        while current.count > 1 {
            result.append(current)
            current = (current as NSString).deletingLastPathComponent
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ScanEngineTests`
Expected: PASS — 17 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages
git commit -m "feat(scan): add probe protocol and concurrent scan engine" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Subprocess runner and the four v1 probes

**Files:**
- Modify: `Package.swift` (add `ProcessKit`, `Probes`, `ProcessKitTests`, `ProbesTests`; `TestSupport` also depends on `ProcessKit`)
- Create: `Packages/OpenCleanKit/Sources/ProcessKit/CommandRunner.swift`
- Create: `Packages/OpenCleanKit/Sources/TestSupport/FakeCommandRunner.swift`
- Create: `Packages/OpenCleanKit/Sources/Probes/XcodeSimulatorsProbe.swift`
- Create: `Packages/OpenCleanKit/Sources/Probes/HomebrewCacheProbe.swift`
- Create: `Packages/OpenCleanKit/Sources/Probes/DockerDiskImageProbe.swift`
- Create: `Packages/OpenCleanKit/Sources/Probes/TimeMachineSnapshotsProbe.swift`
- Create: `Packages/OpenCleanKit/Sources/Probes/StandardProbes.swift`
- Test: `Packages/OpenCleanKit/Tests/ProcessKitTests/CommandRunnerTests.swift`, `Packages/OpenCleanKit/Tests/ProbesTests/ProbesTests.swift`

**Interfaces:**
- Consumes: Task 5 `Probe`, `ProbeFinding`, `ProbeRegistry`, `ScanContext`; Task 2 `FileStat`.
- Produces:
  - `struct CommandOutput: Equatable { status: Int32; stdout: Data; stderr: Data; stdoutText: String; stderrText: String; init(status:stdout:stderr:) }`
  - `enum CommandError: Error { launchFailed(String) }`
  - `protocol CommandRunner: Sendable { func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput }`, `struct ProcessCommandRunner: CommandRunner`
  - `final class FakeCommandRunner: CommandRunner { respond(_ commandLine:status:stdout:stderr:); calls: [[String]] }` (TestSupport; key is the executable and arguments joined with single spaces)
  - `XcodeSimulatorsProbe(runner:)` id `xcode.simulators`; `HomebrewCacheProbe(runner:brewCandidates:)` id `homebrew.cache`; `DockerDiskImageProbe()` id `docker.disk-image`; `TimeMachineSnapshotsProbe(runner:)` id `timemachine.local-snapshots`
  - `extension ProbeRegistry { static var standard: ProbeRegistry }`

- [ ] **Step 1: Add the targets**

Update `Package.swift` `targets:` so it contains (keep existing entries; change `TestSupport`'s dependencies):

```swift
        .target(
            name: "TestSupport",
            dependencies: ["ScanEngine", "ProcessKit"],
            path: "Packages/OpenCleanKit/Sources/TestSupport"
        ),
        .target(
            name: "ProcessKit",
            path: "Packages/OpenCleanKit/Sources/ProcessKit"
        ),
        .target(
            name: "Probes",
            dependencies: ["ScanEngine", "ProcessKit", "RuleKit"],
            path: "Packages/OpenCleanKit/Sources/Probes"
        ),
        .testTarget(
            name: "ProcessKitTests",
            dependencies: ["ProcessKit"],
            path: "Packages/OpenCleanKit/Tests/ProcessKitTests"
        ),
        .testTarget(
            name: "ProbesTests",
            dependencies: ["Probes", "ScanEngine", "ProcessKit", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/ProbesTests"
        ),
```

- [ ] **Step 2: Write the failing tests**

`Packages/OpenCleanKit/Tests/ProcessKitTests/CommandRunnerTests.swift`:

```swift
import Foundation
import Testing
@testable import ProcessKit

struct CommandRunnerTests {
    let runner = ProcessCommandRunner()

    @Test func capturesStdoutAndStatus() throws {
        let output = try runner.run("/bin/echo", ["hello", "world"])
        #expect(output.status == 0)
        #expect(output.stdoutText == "hello world\n")
    }

    @Test func capturesStderrAndFailureStatus() throws {
        let output = try runner.run("/bin/sh", ["-c", "echo oops >&2; exit 3"])
        #expect(output.status == 3)
        #expect(output.stderrText == "oops\n")
    }

    @Test func reportsMissingExecutable() {
        #expect(throws: CommandError.self) { try runner.run("/nonexistent/tool", []) }
    }
}
```

`Packages/OpenCleanKit/Tests/ProbesTests/ProbesTests.swift`:

```swift
import Foundation
import ProcessKit
import ScanEngine
import Testing
import TestSupport
@testable import Probes

struct ProbesTests {
    func context(_ home: TempDirectory) -> ScanContext {
        ScanContext(home: home.path, hasFullDiskAccess: true, processChecker: FakeProcessChecker())
    }

    @Test func xcodeSimulatorsReportsOnlyUnavailableDevices() async throws {
        let home = try TempDirectory()
        let runner = FakeCommandRunner()
        runner.respond(
            "/usr/bin/xcrun simctl list devices --json",
            stdout: """
                {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-16-0": [
                  {"udid": "AAA", "name": "iPhone 14", "isAvailable": false},
                  {"udid": "BBB", "name": "iPhone 15", "isAvailable": true}
                ]}}
                """)
        let findings = try await XcodeSimulatorsProbe(runner: runner).scan(context(home))
        #expect(findings == [
            ProbeFinding(
                path: home.path + "/Library/Developer/CoreSimulator/Devices/AAA",
                hint: "Unavailable simulator: iPhone 14")
        ])
    }

    @Test func xcodeSimulatorsIsEmptyWhenXcrunFails() async throws {
        let home = try TempDirectory()
        let runner = FakeCommandRunner()
        runner.respond("/usr/bin/xcrun simctl list devices --json", status: 1)
        #expect(try await XcodeSimulatorsProbe(runner: runner).scan(context(home)).isEmpty)
    }

    @Test func homebrewCacheListsCacheEntries() async throws {
        let home = try TempDirectory()
        let brew = try home.file("bin/brew")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew)
        try home.file("brew-cache/a.bottle.tar.gz", bytes: 10)
        try home.file("brew-cache/downloads/x", bytes: 10)
        let runner = FakeCommandRunner()
        runner.respond("\(brew) --cache", stdout: home.path + "/brew-cache\n")
        let findings = try await HomebrewCacheProbe(runner: runner, brewCandidates: [brew]).scan(context(home))
        #expect(findings.map(\.path) == [home.path + "/brew-cache/a.bottle.tar.gz", home.path + "/brew-cache/downloads"])
        #expect(findings.allSatisfy { !$0.reportOnly })
    }

    @Test func homebrewCacheIsEmptyWithoutBrew() async throws {
        let home = try TempDirectory()
        let probe = HomebrewCacheProbe(runner: FakeCommandRunner(), brewCandidates: [home.path + "/missing/brew"])
        #expect(try await probe.scan(context(home)).isEmpty)
    }

    @Test func dockerDiskImageIsReportOnly() async throws {
        let home = try TempDirectory()
        let image = try home.file("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", bytes: 10)
        let findings = try await DockerDiskImageProbe().scan(context(home))
        #expect(findings.map(\.path) == [image])
        #expect(findings.allSatisfy(\.reportOnly))
        #expect(findings.first?.hint?.contains("docker system prune") == true)
    }

    @Test func timeMachineSnapshotsAreVirtualReportOnlyFindings() async throws {
        let home = try TempDirectory()
        let runner = FakeCommandRunner()
        runner.respond(
            "/usr/bin/tmutil listlocalsnapshots /",
            stdout: "Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-01-101010.local\n")
        let findings = try await TimeMachineSnapshotsProbe(runner: runner).scan(context(home))
        #expect(findings.map(\.path) == ["tmsnapshot://com.apple.TimeMachine.2026-10-01-101010.local"])
        #expect(findings.allSatisfy(\.reportOnly))
    }

    @Test func standardRegistryHasAllV1Probes() {
        #expect(ProbeRegistry.standard.ids == [
            "xcode.simulators", "homebrew.cache", "docker.disk-image", "timemachine.local-snapshots",
        ])
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter "ProcessKitTests|ProbesTests"`
Expected: build FAILS — `no such module 'ProcessKit'` / `no such module 'Probes'`.

- [ ] **Step 4: Implement**

`Packages/OpenCleanKit/Sources/ProcessKit/CommandRunner.swift`:

```swift
import Foundation

public struct CommandOutput: Sendable, Equatable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum CommandError: Error, Equatable {
    case launchFailed(String)
}

/// Runs an executable directly (never through a shell) and captures its output.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput
}

public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed("\(executable): \(error.localizedDescription)")
        }

        // Drain stderr on another thread so a full pipe buffer can never deadlock the child.
        let stderrHandle = stderrPipe.fileHandleForReading
        let stderrBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stderrBox.set(stderrHandle.readDataToEndOfFile())
            group.leave()
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return CommandOutput(status: process.terminationStatus, stdout: stdoutData, stderr: stderrBox.get())
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) { lock.withLock { data = value } }
    func get() -> Data { lock.withLock { data } }
}
```

`Packages/OpenCleanKit/Sources/TestSupport/FakeCommandRunner.swift`:

```swift
import Foundation
import ProcessKit

/// Returns canned output keyed by "executable arg1 arg2"; unstubbed commands exit 127.
public final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: CommandOutput] = [:]
    private var recorded: [[String]] = []

    public init() {}

    public var calls: [[String]] { lock.withLock { recorded } }

    public func respond(_ commandLine: String, status: Int32 = 0, stdout: String = "", stderr: String = "") {
        lock.withLock {
            responses[commandLine] = CommandOutput(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
        }
    }

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        let line = ([executable] + arguments).joined(separator: " ")
        return lock.withLock {
            recorded.append([executable] + arguments)
            return responses[line] ?? CommandOutput(status: 127, stderr: Data("not stubbed: \(line)".utf8))
        }
    }
}
```

`Packages/OpenCleanKit/Sources/Probes/XcodeSimulatorsProbe.swift`:

```swift
import Foundation
import ProcessKit
import ScanEngine

/// Simulator devices whose runtime is no longer installed (`isAvailable == false`).
public struct XcodeSimulatorsProbe: Probe {
    public static let id = "xcode.simulators"
    let runner: any CommandRunner

    public init(runner: any CommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    struct Listing: Decodable {
        let devices: [String: [Device]]
    }

    struct Device: Decodable {
        let udid: String
        let name: String
        let isAvailable: Bool?
    }

    public func scan(_ context: ScanContext) async throws -> [ProbeFinding] {
        let output: CommandOutput
        do {
            output = try runner.run("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"])
        } catch {
            return []
        }
        guard output.status == 0 else { return [] }
        let listing = try JSONDecoder().decode(Listing.self, from: output.stdout)
        let root = context.home + "/Library/Developer/CoreSimulator/Devices/"
        return listing.devices.values.flatMap { $0 }
            .filter { $0.isAvailable == false }
            .sorted { $0.udid < $1.udid }
            .map { ProbeFinding(path: root + $0.udid, hint: "Unavailable simulator: \($0.name)") }
    }
}
```

`Packages/OpenCleanKit/Sources/Probes/HomebrewCacheProbe.swift`:

```swift
import Foundation
import ProcessKit
import ScanEngine

/// Entries in Homebrew's download cache (`brew --cache`).
public struct HomebrewCacheProbe: Probe {
    public static let id = "homebrew.cache"
    let runner: any CommandRunner
    let brewCandidates: [String]

    public init(
        runner: any CommandRunner = ProcessCommandRunner(),
        brewCandidates: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    ) {
        self.runner = runner
        self.brewCandidates = brewCandidates
    }

    public func scan(_ context: ScanContext) async throws -> [ProbeFinding] {
        guard let brew = brewCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return []
        }
        let output: CommandOutput
        do {
            output = try runner.run(brew, ["--cache"])
        } catch {
            return []
        }
        let cache = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.status == 0, cache.hasPrefix("/") else { return [] }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: cache)) ?? []
        return children.sorted().map { ProbeFinding(path: cache + "/" + $0) }
    }
}
```

`Packages/OpenCleanKit/Sources/Probes/DockerDiskImageProbe.swift`:

```swift
import Foundation
import RuleKit
import ScanEngine

/// Reports Docker Desktop's virtual disk size. Never removable: Docker data is managed by Docker.
public struct DockerDiskImageProbe: Probe {
    public static let id = "docker.disk-image"

    public init() {}

    public func scan(_ context: ScanContext) async throws -> [ProbeFinding] {
        let candidates = [
            "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
            "/Library/Containers/com.docker.docker/Data/vms/0/Docker.raw",
        ].map { context.home + $0 }
        return candidates.filter { FileStat.of($0) != nil }.map {
            ProbeFinding(
                path: $0, reportOnly: true,
                hint: "Docker Desktop's virtual disk. Reclaim space with `docker system prune` or Docker Desktop → Settings → Resources.")
        }
    }
}
```

`Packages/OpenCleanKit/Sources/Probes/TimeMachineSnapshotsProbe.swift`:

```swift
import Foundation
import ProcessKit
import ScanEngine

/// Lists local Time Machine snapshots. Report-only in this release.
public struct TimeMachineSnapshotsProbe: Probe {
    public static let id = "timemachine.local-snapshots"
    let runner: any CommandRunner

    public init(runner: any CommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func scan(_ context: ScanContext) async throws -> [ProbeFinding] {
        let output: CommandOutput
        do {
            output = try runner.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        } catch {
            return []
        }
        guard output.status == 0 else { return [] }
        return output.stdoutText.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.TimeMachine.") }
            .map {
                ProbeFinding(
                    path: "tmsnapshot://\($0)", reportOnly: true,
                    hint: "Local Time Machine snapshot. macOS removes these when space is needed; manage with `tmutil deletelocalsnapshots`.")
            }
    }
}
```

`Packages/OpenCleanKit/Sources/Probes/StandardProbes.swift`:

```swift
import ScanEngine

extension ProbeRegistry {
    /// Every probe shipped with OpenClean v1.
    public static var standard: ProbeRegistry {
        ProbeRegistry([
            XcodeSimulatorsProbe(), HomebrewCacheProbe(), DockerDiskImageProbe(), TimeMachineSnapshotsProbe(),
        ])
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter "ProcessKitTests|ProbesTests"`
Expected: PASS — 10 tests.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Packages
git commit -m "feat(probes): add command runner and xcode, homebrew, docker, time machine probes" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 7: Admin-prompt command builder and executor

**Files:**
- Modify: `Package.swift` (add `Privilege`, `PrivilegeTests`)
- Create: `Packages/OpenCleanKit/Sources/Privilege/AdminCommandBuilder.swift`
- Create: `Packages/OpenCleanKit/Sources/Privilege/AdminExecutor.swift`
- Test: `Packages/OpenCleanKit/Tests/PrivilegeTests/PrivilegeTests.swift`

**Interfaces:**
- Consumes: Task 6 `CommandRunner`, `ProcessCommandRunner`, `CommandOutput`, `FakeCommandRunner`.
- Produces:
  - `enum AdminCommandError: Error, Equatable { noPaths, invalidPath(String), tooLong }`
  - `enum AdminCommandBuilder { static let maxCommandLength: Int; static func shellQuote(_:) -> String; static func appleScriptLiteral(_:) -> String; static func removalCommand(paths: [String]) throws -> String; static func appleScript(forShellCommand:) -> String }`
  - `enum AdminRunOutcome: Equatable { succeeded, cancelled, failed(String) }`
  - `protocol AdminExecutor: Sendable { func runAsAdmin(shellCommand: String) -> AdminRunOutcome }`, `struct OsascriptAdminExecutor: AdminExecutor { init(runner:) }`

- [ ] **Step 1: Add the targets**

Append to `Package.swift` `targets:`:

```swift
        .target(
            name: "Privilege",
            dependencies: ["ProcessKit"],
            path: "Packages/OpenCleanKit/Sources/Privilege"
        ),
        .testTarget(
            name: "PrivilegeTests",
            dependencies: ["Privilege", "ProcessKit", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/PrivilegeTests"
        ),
```

- [ ] **Step 2: Write the failing tests**

`Packages/OpenCleanKit/Tests/PrivilegeTests/PrivilegeTests.swift`:

```swift
import Foundation
import ProcessKit
import Testing
import TestSupport
@testable import Privilege

struct AdminCommandBuilderTests {
    @Test func quotesForTheShell() {
        #expect(AdminCommandBuilder.shellQuote("plain") == "'plain'")
        #expect(AdminCommandBuilder.shellQuote("a'b") == #"'a'\''b'"#)
    }

    @Test func escapesForAppleScript() {
        #expect(AdminCommandBuilder.appleScriptLiteral(#"a"b\c"#) == #""a\"b\\c""#)
    }

    @Test func buildsOneRmInvocationWithEndOfOptions() throws {
        let command = try AdminCommandBuilder.removalCommand(paths: ["/Library/Caches/a", "/private/var/log/b.gz"])
        #expect(command == "/bin/rm -rf -- '/Library/Caches/a' '/private/var/log/b.gz'")
    }

    @Test func rejectsUnsafePaths() {
        #expect(throws: AdminCommandError.noPaths) { try AdminCommandBuilder.removalCommand(paths: []) }
        #expect(throws: AdminCommandError.invalidPath("relative")) {
            try AdminCommandBuilder.removalCommand(paths: ["relative"])
        }
        #expect(throws: AdminCommandError.invalidPath("/")) { try AdminCommandBuilder.removalCommand(paths: ["/"]) }
        #expect(throws: AdminCommandError.invalidPath("/a\nb")) {
            try AdminCommandBuilder.removalCommand(paths: ["/a\nb"])
        }
        let long = Array(repeating: "/Library/Caches/" + String(repeating: "x", count: 200), count: 5_000)
        #expect(throws: AdminCommandError.tooLong) { try AdminCommandBuilder.removalCommand(paths: long) }
    }

    @Test func hostileNamesAreRemovedLiterally() throws {
        let dir = try TempDirectory()
        let names = ["a'b", "$(touch PWNED)", "x\"y", "sp ace", "-rf", #"back\slash"#, "emoji 🧹", "semi;colon"]
        let paths = try names.map { try dir.file("victims/" + $0, bytes: 1) }
        try dir.file("victims/keep.txt", bytes: 1)

        let command = try AdminCommandBuilder.removalCommand(paths: paths)
        let output = try ProcessCommandRunner().run("/bin/sh", ["-c", command])

        #expect(output.status == 0, "\(output.stderrText)")
        for path in paths { #expect(!FileManager.default.fileExists(atPath: path), "\(path) survived") }
        #expect(FileManager.default.fileExists(atPath: dir.path + "/victims/keep.txt"))
        #expect(!FileManager.default.fileExists(atPath: dir.path + "/victims/PWNED"))
        #expect(!FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/PWNED"))
    }

    @Test func appleScriptLiteralRoundTripsThroughOsascript() throws {
        let command = try AdminCommandBuilder.removalCommand(paths: [#"/tmp/a'b"c\d 🧹"#])
        let output = try ProcessCommandRunner().run(
            "/usr/bin/osascript", ["-e", "return " + AdminCommandBuilder.appleScriptLiteral(command)])
        #expect(output.status == 0, "\(output.stderrText)")
        #expect(output.stdoutText == command + "\n")
    }
}

struct OsascriptAdminExecutorTests {
    let command = "/bin/rm -rf -- '/Library/Caches/a'"
    var script: String { AdminCommandBuilder.appleScript(forShellCommand: command) }

    @Test func runsOsascriptWithAdministratorPrivileges() {
        let runner = FakeCommandRunner()
        runner.respond("/usr/bin/osascript -e " + script)
        #expect(OsascriptAdminExecutor(runner: runner).runAsAdmin(shellCommand: command) == .succeeded)
        #expect(runner.calls == [["/usr/bin/osascript", "-e", script]])
        #expect(script.hasSuffix("with administrator privileges"))
    }

    @Test func mapsUserCancelToCancelled() {
        let runner = FakeCommandRunner()
        runner.respond(
            "/usr/bin/osascript -e " + script, status: 1,
            stderr: "0:105: execution error: User canceled. (-128)\n")
        #expect(OsascriptAdminExecutor(runner: runner).runAsAdmin(shellCommand: command) == .cancelled)
    }

    @Test func mapsOtherErrorsToFailed() {
        let runner = FakeCommandRunner()
        runner.respond("/usr/bin/osascript -e " + script, status: 1, stderr: "rm: permission denied\n")
        #expect(
            OsascriptAdminExecutor(runner: runner).runAsAdmin(shellCommand: command)
                == .failed("rm: permission denied"))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter PrivilegeTests`
Expected: build FAILS — `no such module 'Privilege'`.

- [ ] **Step 4: Implement**

`Packages/OpenCleanKit/Sources/Privilege/AdminCommandBuilder.swift`:

```swift
import Foundation

public enum AdminCommandError: Error, Equatable {
    case noPaths
    case invalidPath(String)
    case tooLong
}

/// Builds the single root command used to delete already-validated, root-owned paths.
/// Paths are passed as individually single-quoted arguments after `--`; nothing is globbed.
public enum AdminCommandBuilder {
    /// Stays well below ARG_MAX (1 MiB) once AppleScript escaping is added.
    public static let maxCommandLength = 400_000

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    public static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
        return "\"" + escaped + "\""
    }

    public static func removalCommand(paths: [String]) throws -> String {
        guard !paths.isEmpty else { throw AdminCommandError.noPaths }
        for path in paths {
            let unsafe = path.contains("\n") || path.contains("\r") || path.contains("\0")
            guard path.hasPrefix("/"), path != "/", !unsafe else {
                throw AdminCommandError.invalidPath(path)
            }
        }
        let command = "/bin/rm -rf -- " + paths.map(shellQuote).joined(separator: " ")
        guard command.utf8.count <= maxCommandLength else { throw AdminCommandError.tooLong }
        return command
    }

    public static func appleScript(forShellCommand command: String) -> String {
        "do shell script \(appleScriptLiteral(command)) with administrator privileges"
    }
}
```

`Packages/OpenCleanKit/Sources/Privilege/AdminExecutor.swift`:

```swift
import Foundation
import ProcessKit

public enum AdminRunOutcome: Sendable, Equatable {
    case succeeded
    case cancelled
    case failed(String)
}

public protocol AdminExecutor: Sendable {
    func runAsAdmin(shellCommand: String) -> AdminRunOutcome
}

/// Shows the standard macOS administrator prompt via `osascript`. One call = one prompt.
public struct OsascriptAdminExecutor: AdminExecutor {
    let runner: any CommandRunner

    public init(runner: any CommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func runAsAdmin(shellCommand: String) -> AdminRunOutcome {
        let script = AdminCommandBuilder.appleScript(forShellCommand: shellCommand)
        do {
            let output = try runner.run("/usr/bin/osascript", ["-e", script])
            if output.status == 0 { return .succeeded }
            if output.stderrText.contains("-128") { return .cancelled }
            return .failed(output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failed("\(error)")
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter PrivilegeTests`
Expected: PASS — 9 tests.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Packages
git commit -m "feat(privilege): add quoted admin removal command and osascript executor" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Quarantine manifest and session store

**Files:**
- Modify: `Package.swift` (add `Quarantine`, `QuarantineTests`)
- Create: `Packages/OpenCleanKit/Sources/Quarantine/Manifest.swift`
- Create: `Packages/OpenCleanKit/Sources/Quarantine/QuarantineStore.swift`
- Test: `Packages/OpenCleanKit/Tests/QuarantineTests/QuarantineStoreTests.swift`

**Interfaces:**
- Consumes: Task 1 `DeleteMode`; Task 2 `FileStat`.
- Produces:
  - `enum EntryOutcome: String, Codable { pending, deleted, quarantined, trashed, skipped, failed, restored, purged }`
  - `struct ManifestEntry: Codable, Equatable, Identifiable { id: Int; originalPath: String; storedPath: String?; size: Int64; ruleID: String; mode: DeleteMode; outcome: EntryOutcome; reason: String? }`
  - `struct SessionManifest: Codable, Equatable, Identifiable { schema: Int; id: String; createdAt: Date; purgedAt: Date?; entries: [ManifestEntry]; deletedBytes; quarantinedBytes; skippedEntries; restorableEntries; bytes(_:) }`
  - `enum SessionListing: Identifiable { ok(SessionManifest), damaged(id: String, created: Date?); id; date }`
  - `enum QuarantineError: Error, Equatable { sessionNotFound(String) }`
  - `struct QuarantineStore { root: URL; init(root:); createSession(now:) throws -> SessionManifest; write(_:) throws; read(id:) throws -> SessionManifest; listSessions() -> [SessionListing]; sessionDirectory(_:) -> URL; itemsDirectory(_:) -> URL }`
  - `extension Date { var wholeSeconds: Date }`

- [ ] **Step 1: Add the targets**

Append to `Package.swift` `targets:`:

```swift
        .target(
            name: "Quarantine",
            dependencies: ["RuleKit", "ScanEngine", "Privilege", "ProcessKit"],
            path: "Packages/OpenCleanKit/Sources/Quarantine"
        ),
        .testTarget(
            name: "QuarantineTests",
            dependencies: ["Quarantine", "RuleKit", "ScanEngine", "Privilege", "ProcessKit", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/QuarantineTests"
        ),
```

- [ ] **Step 2: Write the failing tests**

`Packages/OpenCleanKit/Tests/QuarantineTests/QuarantineStoreTests.swift`:

```swift
import Foundation
import RuleKit
import Testing
import TestSupport
@testable import Quarantine

struct QuarantineStoreTests {
    @Test func createSessionMakesItemsDirectoryAndManifest() throws {
        let dir = try TempDirectory()
        let store = QuarantineStore(root: dir.url.appendingPathComponent("Quarantine"))
        let session = try store.createSession(now: Date(timeIntervalSince1970: 1_800_000_000.75))
        #expect(FileStat.of(store.itemsDirectory(session.id).path)?.isDirectory == true)
        #expect(session.createdAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try store.read(id: session.id) == session)
        #expect(session.id.range(of: #"^\d{8}-\d{6}-[0-9a-f]{4}$"#, options: .regularExpression) != nil)
    }

    @Test func roundTripsEntries() throws {
        let dir = try TempDirectory()
        let store = QuarantineStore(root: dir.url)
        var session = try store.createSession()
        session.entries = [
            ManifestEntry(
                id: 0, originalPath: "/a", storedPath: nil, size: 10, ruleID: "r", mode: .immediate,
                outcome: .deleted, reason: nil),
            ManifestEntry(
                id: 1, originalPath: "/b", storedPath: "/q/1/b", size: 20, ruleID: "r", mode: .quarantine,
                outcome: .quarantined, reason: nil),
            ManifestEntry(
                id: 2, originalPath: "/c", storedPath: nil, size: 30, ruleID: "r", mode: .immediate,
                outcome: .skipped, reason: "in use"),
        ]
        try store.write(session)
        let loaded = try store.read(id: session.id)
        #expect(loaded == session)
        #expect(loaded.deletedBytes == 10)
        #expect(loaded.quarantinedBytes == 20)
        #expect(loaded.skippedEntries.map(\.originalPath) == ["/c"])
        #expect(loaded.restorableEntries.map(\.originalPath) == ["/b"])
    }

    @Test func listsNewestFirstAndFlagsDamagedSessions() throws {
        let dir = try TempDirectory()
        let store = QuarantineStore(root: dir.url)
        let older = try store.createSession(now: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = try store.createSession(now: Date(timeIntervalSince1970: 1_800_000_000))
        try FileManager.default.createDirectory(at: store.sessionDirectory("broken"), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.sessionDirectory("broken").appendingPathComponent("manifest.json"))

        let listings = store.listSessions()
        let okIDs = listings.compactMap { listing -> String? in
            if case .ok(let manifest) = listing { return manifest.id }
            return nil
        }
        let damagedIDs = listings.compactMap { listing -> String? in
            if case .damaged(let id, _) = listing { return id }
            return nil
        }
        #expect(okIDs == [newer.id, older.id])
        #expect(damagedIDs == ["broken"])
    }

    @Test func readingUnknownSessionThrows() throws {
        let dir = try TempDirectory()
        #expect(throws: QuarantineError.sessionNotFound("nope")) {
            try QuarantineStore(root: dir.url).read(id: "nope")
        }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter QuarantineTests`
Expected: build FAILS — `no such module 'Quarantine'`.

- [ ] **Step 4: Implement**

`Packages/OpenCleanKit/Sources/Quarantine/Manifest.swift`:

```swift
import Foundation
import RuleKit

public enum EntryOutcome: String, Codable, Sendable {
    case pending, deleted, quarantined, trashed, skipped, failed, restored, purged
}

public struct ManifestEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var originalPath: String
    /// Planned (while pending) or actual location of the stored copy.
    public var storedPath: String?
    public var size: Int64
    public var ruleID: String
    public var mode: DeleteMode
    public var outcome: EntryOutcome
    public var reason: String?

    public init(
        id: Int, originalPath: String, storedPath: String?, size: Int64, ruleID: String,
        mode: DeleteMode, outcome: EntryOutcome, reason: String?
    ) {
        self.id = id
        self.originalPath = originalPath
        self.storedPath = storedPath
        self.size = size
        self.ruleID = ruleID
        self.mode = mode
        self.outcome = outcome
        self.reason = reason
    }
}

public struct SessionManifest: Codable, Sendable, Equatable, Identifiable {
    public var schema: Int = 1
    public var id: String
    public var createdAt: Date
    public var purgedAt: Date?
    public var entries: [ManifestEntry]

    public init(id: String, createdAt: Date, purgedAt: Date? = nil, entries: [ManifestEntry] = []) {
        self.id = id
        self.createdAt = createdAt
        self.purgedAt = purgedAt
        self.entries = entries
    }

    public func bytes(_ outcomes: Set<EntryOutcome>) -> Int64 {
        entries.filter { outcomes.contains($0.outcome) }.reduce(0) { $0 + $1.size }
    }

    public var deletedBytes: Int64 { bytes([.deleted]) }
    public var quarantinedBytes: Int64 { bytes([.quarantined, .trashed]) }
    public var skippedEntries: [ManifestEntry] { entries.filter { $0.outcome == .skipped || $0.outcome == .failed } }

    /// Entries whose stored copy can be moved back (including ones a crash left pending).
    public var restorableEntries: [ManifestEntry] {
        entries.filter { [.quarantined, .trashed, .pending].contains($0.outcome) && $0.storedPath != nil }
    }
}

extension Date {
    /// Truncated to whole seconds so ISO-8601 manifests round-trip exactly.
    public var wholeSeconds: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
```

`Packages/OpenCleanKit/Sources/Quarantine/QuarantineStore.swift`:

```swift
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter QuarantineTests`
Expected: PASS — 4 tests.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Packages
git commit -m "feat(quarantine): add session manifest and store" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Pre-delete checks and open-file detection

**Files:**
- Create: `Packages/OpenCleanKit/Sources/Quarantine/OpenFiles.swift`
- Create: `Packages/OpenCleanKit/Sources/Quarantine/PreDeleteChecker.swift`
- Test: `Packages/OpenCleanKit/Tests/QuarantineTests/PreDeleteCheckerTests.swift`

**Interfaces:**
- Consumes: Task 2 `FileStat`, `DenyList`; Task 4 `ScanItem`, `ProcessChecker`, `FakeProcessChecker`; Task 6 `CommandRunner`.
- Produces:
  - `protocol OpenFilesProvider: Sendable { func openPaths() throws -> Set<String> }`
  - `struct LsofOpenFilesProvider: OpenFilesProvider { init(runner:) }`, `enum LsofParser { static func paths(from: String) -> Set<String> }`, `enum LsofError: Error { noOutput(status: Int32) }`
  - `enum SkipReason: Equatable, CustomStringConvertible { reportOnly, missing, changedSinceScan, inUse, openFilesUnknown, appRunning(String), protected(String), adminCancelled, adminUnsupportedPath, adminBatchFull }`
  - `struct PreDeleteChecker { init(denyList:processChecker:openPaths: Set<String>?); check(_ item: ScanItem, rule: Rule) -> SkipReason? }`

- [ ] **Step 1: Write the failing tests**

`Packages/OpenCleanKit/Tests/QuarantineTests/PreDeleteCheckerTests.swift`:

```swift
import Foundation
import RuleKit
import ScanEngine
import Testing
import TestSupport
@testable import Quarantine

struct PreDeleteCheckerTests {
    func rule(appNotRunning: [String] = []) -> Rule {
        Rule(
            id: "r", name: "R", category: .user, explain: "x", paths: ["~/x"], safety: .regenerable,
            conditions: RuleConditions(appNotRunning: appNotRunning))
    }

    func checker(
        _ home: TempDirectory, running: Set<String> = [], openPaths: Set<String>? = []
    ) -> PreDeleteChecker {
        PreDeleteChecker(
            denyList: DenyList(home: home.path), processChecker: FakeProcessChecker(running: running),
            openPaths: openPaths)
    }

    @Test func passesUnchangedItem() throws {
        let home = try TempDirectory()
        let item = try #require(ScanItem.snapshot(of: try home.file("cache/a", bytes: 10), ruleID: "r"))
        #expect(checker(home).check(item, rule: rule()) == nil)
    }

    @Test func skipsMissingItem() throws {
        let home = try TempDirectory()
        let path = try home.file("cache/a", bytes: 10)
        let item = try #require(ScanItem.snapshot(of: path, ruleID: "r"))
        try FileManager.default.removeItem(atPath: path)
        #expect(checker(home).check(item, rule: rule()) == .missing)
    }

    @Test func skipsChangedItem() throws {
        let home = try TempDirectory()
        let path = try home.file("cache/a", bytes: 10)
        let item = try #require(ScanItem.snapshot(of: path, ruleID: "r"))
        try FileManager.default.setAttributes(
            [.modificationDate: item.modificationDate.addingTimeInterval(10)], ofItemAtPath: path)
        #expect(checker(home).check(item, rule: rule()) == .changedSinceScan)
    }

    @Test func skipsReplacedItem() throws {
        let home = try TempDirectory()
        let path = try home.file("cache/a", bytes: 10)
        let item = try #require(ScanItem.snapshot(of: path, ruleID: "r"))
        try FileManager.default.removeItem(atPath: path)
        try home.file("cache/a", bytes: 10, modified: item.modificationDate)
        #expect(checker(home).check(item, rule: rule()) == .changedSinceScan)
    }

    @Test func skipsItemsContainingOpenFiles() throws {
        let home = try TempDirectory()
        let dir = try home.directory("cache/db")
        try home.file("cache/db/store.sqlite", bytes: 10)
        let item = try #require(ScanItem.snapshot(of: dir, ruleID: "r"))
        let busy = checker(home, openPaths: [dir + "/store.sqlite"])
        #expect(busy.check(item, rule: rule()) == .inUse)
    }

    @Test func skipsEverythingWhenOpenFilesAreUnknown() throws {
        let home = try TempDirectory()
        let item = try #require(ScanItem.snapshot(of: try home.file("cache/a", bytes: 10), ruleID: "r"))
        #expect(checker(home, openPaths: nil).check(item, rule: rule()) == .openFilesUnknown)
    }

    @Test func skipsWhenAppStartedSinceScan() throws {
        let home = try TempDirectory()
        let item = try #require(ScanItem.snapshot(of: try home.file("cache/a", bytes: 10), ruleID: "r"))
        let result = checker(home, running: ["com.example"]).check(item, rule: rule(appNotRunning: ["com.example"]))
        #expect(result == .appRunning("com.example"))
    }

    @Test func skipsProtectedPaths() throws {
        let home = try TempDirectory()
        let item = try #require(ScanItem.snapshot(of: try home.file("Documents/a", bytes: 10), ruleID: "r"))
        #expect(checker(home).check(item, rule: rule()) == .protected("inside protected location \(home.path)/Documents"))
    }

    @Test func neverPassesReportOnlyItems() throws {
        let home = try TempDirectory()
        let item = ScanItem.virtual(path: "tmsnapshot://x", ruleID: "r", hint: nil)
        #expect(checker(home).check(item, rule: rule()) == .reportOnly)
    }

    @Test func parsesLsofFieldOutput() {
        let text = "p123\nfcwd\nn/Users/a\nf4\nn/Users/a/file.db\nf5\nnlocalhost:443->x\np456\nf1\nn/dev/null\n"
        #expect(LsofParser.paths(from: text) == ["/Users/a", "/Users/a/file.db", "/dev/null"])
    }

    @Test func lsofSeesFilesOpenInThisProcess() throws {
        let home = try TempDirectory()
        let file = try home.file("cache/open.db", bytes: 10)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
        defer { try? handle.close() }
        #expect(try LsofOpenFilesProvider().openPaths().contains(file))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PreDeleteCheckerTests`
Expected: build FAILS — `cannot find 'PreDeleteChecker' in scope`.

- [ ] **Step 3: Implement**

`Packages/OpenCleanKit/Sources/Quarantine/OpenFiles.swift`:

```swift
import Foundation
import ProcessKit

public protocol OpenFilesProvider: Sendable {
    /// Absolute paths currently open by processes this user can inspect.
    func openPaths() throws -> Set<String>
}

public enum LsofError: Error, Equatable {
    case noOutput(status: Int32)
}

/// One `lsof` call per cleanup session, in machine-readable field mode.
public struct LsofOpenFilesProvider: OpenFilesProvider {
    let runner: any CommandRunner

    public init(runner: any CommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func openPaths() throws -> Set<String> {
        let output = try runner.run("/usr/sbin/lsof", ["-n", "-P", "-w", "-F", "n"])
        // lsof exits 1 when some processes could not be inspected; output is still usable.
        guard !output.stdout.isEmpty else { throw LsofError.noOutput(status: output.status) }
        return LsofParser.paths(from: output.stdoutText)
    }
}

public enum LsofParser {
    public static func paths(from text: String) -> Set<String> {
        var paths = Set<String>()
        for line in text.split(separator: "\n") where line.hasPrefix("n/") {
            paths.insert(String(line.dropFirst()))
        }
        return paths
    }
}
```

`Packages/OpenCleanKit/Sources/Quarantine/PreDeleteChecker.swift`:

```swift
import Foundation
import RuleKit
import ScanEngine

public enum SkipReason: Sendable, Equatable, CustomStringConvertible {
    case reportOnly
    case missing
    case changedSinceScan
    case inUse
    case openFilesUnknown
    case appRunning(String)
    case protected(String)
    case adminCancelled
    case adminUnsupportedPath
    case adminBatchFull

    public var description: String {
        switch self {
        case .reportOnly: "report-only item; never removed"
        case .missing: "no longer exists"
        case .changedSinceScan: "changed since the scan"
        case .inUse: "open in another app"
        case .openFilesUnknown: "could not check for open files"
        case .appRunning(let id): "\(id) is running"
        case .protected(let reason): "protected (\(reason))"
        case .adminCancelled: "administrator prompt was cancelled"
        case .adminUnsupportedPath: "path cannot be passed safely to the administrator prompt"
        case .adminBatchFull: "too many system items for one prompt; run cleanup again"
        }
    }
}

/// Last checks right before an item is removed. Any failure means "skip and record why".
public struct PreDeleteChecker: Sendable {
    let denyList: DenyList
    let processChecker: any ProcessChecker
    /// Open paths plus all their ancestors; nil when open files could not be determined.
    let busy: Set<String>?

    public init(denyList: DenyList, processChecker: any ProcessChecker, openPaths: Set<String>?) {
        self.denyList = denyList
        self.processChecker = processChecker
        guard let openPaths else {
            busy = nil
            return
        }
        var expanded = Set<String>()
        for path in openPaths {
            expanded.insert(path)
            var parent = (path as NSString).deletingLastPathComponent
            while parent.count > 1 {
                expanded.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        busy = expanded
    }

    public func check(_ item: ScanItem, rule: Rule) -> SkipReason? {
        if item.reportOnly { return .reportOnly }
        guard let stat = FileStat.of(item.path) else { return .missing }
        if stat.inode != item.inode || stat.device != item.device || stat.modificationDate != item.modificationDate {
            return .changedSinceScan
        }
        if let reason = denyList.denialReason(for: item.path) { return .protected(reason) }
        if let app = rule.conditions.appNotRunning.first(where: { processChecker.isRunning(bundleID: $0) }) {
            return .appRunning(app)
        }
        guard let busy else { return .openFilesUnknown }
        if busy.contains(item.path) { return .inUse }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PreDeleteCheckerTests`
Expected: PASS — 11 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages
git commit -m "feat(quarantine): add pre-delete checks and lsof open-file detection" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Remover and the file-removal guard test

**Files:**
- Modify: `Package.swift` (`TestSupport` also depends on `Privilege` and `Quarantine`)
- Create: `Packages/OpenCleanKit/Sources/Quarantine/Remover.swift`
- Create: `Packages/OpenCleanKit/Sources/TestSupport/FakeAdminExecutor.swift`
- Create: `Packages/OpenCleanKit/Sources/TestSupport/FakeOpenFiles.swift`
- Test: `Packages/OpenCleanKit/Tests/QuarantineTests/RemoverTests.swift`, `Packages/OpenCleanKit/Tests/QuarantineTests/RemovalGuardTests.swift`

**Interfaces:**
- Consumes: Task 7 `AdminExecutor`, `AdminCommandBuilder`, `AdminRunOutcome`; Task 8 `QuarantineStore`, `SessionManifest`, `ManifestEntry`; Task 9 `PreDeleteChecker`, `SkipReason`; Task 4 `ScanItem`.
- Produces:
  - `struct RemovalRequest { item: ScanItem; rule: Rule; init(item:rule:) }`
  - `struct RemovalReport { manifest: SessionManifest; deletedBytes; quarantinedBytes; skipped: [ManifestEntry]; hadSkips: Bool }`
  - `typealias TrashOperation = @Sendable (String) throws -> String?`
  - `struct Remover { init(store:checker:admin:deviceOf:trash:); remove(_ requests: [RemovalRequest], now: Date = .now) throws -> RemovalReport; static let systemTrash: TrashOperation }`
  - `final class FakeAdminExecutor: AdminExecutor { init(outcome:runForReal:); commands: [String] }`, `struct FakeOpenFiles: OpenFilesProvider { init(_ paths: Set<String>?) }` (TestSupport)

- [ ] **Step 1: Give TestSupport the new dependencies**

In `Package.swift`, change the `TestSupport` target to:

```swift
        .target(
            name: "TestSupport",
            dependencies: ["ScanEngine", "ProcessKit", "Privilege", "Quarantine"],
            path: "Packages/OpenCleanKit/Sources/TestSupport"
        ),
```

- [ ] **Step 2: Add the fakes**

`Packages/OpenCleanKit/Sources/TestSupport/FakeAdminExecutor.swift`:

```swift
import Foundation
import Privilege
import ProcessKit

/// Records admin commands; optionally runs them with /bin/sh as the current (non-root) user.
public final class FakeAdminExecutor: AdminExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    let outcome: AdminRunOutcome
    let runForReal: Bool

    public init(outcome: AdminRunOutcome = .succeeded, runForReal: Bool = false) {
        self.outcome = outcome
        self.runForReal = runForReal
    }

    public var commands: [String] { lock.withLock { recorded } }

    public func runAsAdmin(shellCommand: String) -> AdminRunOutcome {
        lock.withLock { recorded.append(shellCommand) }
        if runForReal && outcome == .succeeded {
            _ = try? ProcessCommandRunner().run("/bin/sh", ["-c", shellCommand])
        }
        return outcome
    }
}
```

`Packages/OpenCleanKit/Sources/TestSupport/FakeOpenFiles.swift`:

```swift
import Quarantine

public struct FakeOpenFiles: OpenFilesProvider {
    struct Unavailable: Error {}
    let paths: Set<String>?

    public init(_ paths: Set<String>? = []) {
        self.paths = paths
    }

    public func openPaths() throws -> Set<String> {
        guard let paths else { throw Unavailable() }
        return paths
    }
}
```

- [ ] **Step 3: Write the failing tests**

`Packages/OpenCleanKit/Tests/QuarantineTests/RemoverTests.swift`:

```swift
import Foundation
import Privilege
import RuleKit
import ScanEngine
import Testing
import TestSupport
@testable import Quarantine

struct RemoverTests {
    func request(
        _ path: String, safety: SafetyLevel = .regenerable, deleteMode: DeleteMode? = nil,
        requires: [Requirement] = []
    ) throws -> RemovalRequest {
        let rule = Rule(
            id: "r.\(safety.rawValue)", name: "R", category: .user, explain: "x", paths: ["~/x"],
            safety: safety, deleteMode: deleteMode, requires: requires)
        return RemovalRequest(item: try #require(ScanItem.snapshot(of: path, ruleID: rule.id)), rule: rule)
    }

    func remover(
        _ home: TempDirectory, admin: FakeAdminExecutor = FakeAdminExecutor(),
        deviceOf: @escaping @Sendable (String) -> Int32? = { FileStat.of($0)?.device },
        trash: @escaping TrashOperation = { _ in nil }
    ) -> (Remover, QuarantineStore) {
        let store = QuarantineStore(root: home.url.appendingPathComponent("Quarantine"))
        let checker = PreDeleteChecker(
            denyList: DenyList(home: home.path), processChecker: FakeProcessChecker(), openPaths: [])
        return (Remover(store: store, checker: checker, admin: admin, deviceOf: deviceOf, trash: trash), store)
    }

    @Test func deletesRegenerableItemsImmediately() throws {
        let home = try TempDirectory()
        let path = try home.file("Library/Caches/a/blob", bytes: 4_096)
        let (remover, _) = remover(home)
        let report = try remover.remove([try request(home.path + "/Library/Caches/a")])
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(report.manifest.entries.map(\.outcome) == [.deleted])
        #expect(report.deletedBytes >= 4_096)
        #expect(!report.hadSkips)
    }

    @Test func quarantinesReviewItemsOnTheSameVolume() throws {
        let home = try TempDirectory()
        let path = try home.file("Downloads/old.dmg", bytes: 2_048)
        let (remover, store) = remover(home)
        let report = try remover.remove([try request(path, safety: .review)])
        let entry = try #require(report.manifest.entries.first)
        let stored = try #require(entry.storedPath)
        #expect(entry.outcome == .quarantined)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(stored.hasPrefix(store.itemsDirectory(report.manifest.id).path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: stored)) == Data(repeating: 0xAB, count: 2_048))
        #expect(report.quarantinedBytes >= 2_048)
    }

    @Test func usesTrashForItemsOnOtherVolumes() throws {
        let home = try TempDirectory()
        let path = try home.file("Volume/file.bin", bytes: 10)
        let fakeTrash = try home.directory("FakeTrash")
        let (remover, _) = remover(
            home,
            deviceOf: { $0.hasPrefix(path) ? 999 : FileStat.of($0)?.device },
            trash: { source in
                let destination = fakeTrash + "/" + (source as NSString).lastPathComponent
                try FileManager.default.moveItem(atPath: source, toPath: destination)
                return destination
            })
        let report = try remover.remove([try request(path, safety: .review)])
        #expect(report.manifest.entries.first?.outcome == .trashed)
        #expect(report.manifest.entries.first?.storedPath == fakeTrash + "/file.bin")
    }

    @Test func missingItemIsSkippedNotFailed() throws {
        let home = try TempDirectory()
        let path = try home.file("Library/Caches/gone", bytes: 10)
        let req = try request(path)
        try FileManager.default.removeItem(atPath: path)
        let report = try remover(home).0.remove([req])
        #expect(report.manifest.entries.first?.outcome == .skipped)
        #expect(report.manifest.entries.first?.reason == "no longer exists")
        #expect(report.hadSkips)
    }

    @Test func reportOnlyItemsAreNeverRemoved() throws {
        let home = try TempDirectory()
        let path = try home.file("Docker.raw", bytes: 10)
        let real = try request(path)
        let item = ScanItem(
            path: real.item.path, ruleID: "r", size: 10, device: real.item.device, inode: real.item.inode,
            modificationDate: real.item.modificationDate, ownerUID: real.item.ownerUID, reportOnly: true)
        let report = try remover(home).0.remove([RemovalRequest(item: item, rule: real.rule)])
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(report.manifest.entries.first?.outcome == .skipped)
    }

    @Test func adminItemsShareOnePrompt() throws {
        let home = try TempDirectory()
        let a = try home.file("sys/a", bytes: 10)
        let b = try home.file("sys/b", bytes: 10)
        let admin = FakeAdminExecutor(outcome: .succeeded, runForReal: true)
        let report = try remover(home, admin: admin).0.remove([
            try request(a, requires: [.admin]), try request(b, requires: [.admin]),
        ])
        #expect(admin.commands.count == 1)
        #expect(report.manifest.entries.map(\.outcome) == [.deleted, .deleted])
        #expect(!FileManager.default.fileExists(atPath: a))
    }

    @Test func cancelledAdminPromptSkipsAndKeepsFiles() throws {
        let home = try TempDirectory()
        let a = try home.file("sys/a", bytes: 10)
        let admin = FakeAdminExecutor(outcome: .cancelled)
        let report = try remover(home, admin: admin).0.remove([try request(a, requires: [.admin])])
        #expect(FileManager.default.fileExists(atPath: a))
        #expect(report.manifest.entries.first?.outcome == .skipped)
        #expect(report.manifest.entries.first?.reason == "administrator prompt was cancelled")
    }

    @Test func pathsWithNewlinesNeverReachTheAdminPrompt() throws {
        let home = try TempDirectory()
        let odd = try home.file("sys/line\nbreak", bytes: 10)
        let admin = FakeAdminExecutor()
        let report = try remover(home, admin: admin).0.remove([try request(odd, requires: [.admin])])
        #expect(admin.commands.isEmpty)
        #expect(report.manifest.entries.first?.reason == SkipReason.adminUnsupportedPath.description)
    }

    @Test func persistsTheFinalManifest() throws {
        let home = try TempDirectory()
        let path = try home.file("Library/Caches/x", bytes: 10)
        let (remover, store) = remover(home)
        let report = try remover.remove([try request(path)])
        #expect(try store.read(id: report.manifest.id) == report.manifest)
    }
}
```

`Packages/OpenCleanKit/Tests/QuarantineTests/RemovalGuardTests.swift`:

```swift
import Foundation
import Testing

/// Only Quarantine and Privilege may remove files. Everything else in the product must not.
struct RemovalGuardTests {
    static let forbidden = ["removeItem(", "trashItem(", "unlink(", "rmdir(", "\"/bin/rm\""]
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
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test --filter "RemoverTests|RemovalGuardTests"`
Expected: build FAILS — `cannot find 'Remover' in scope`, `cannot find type 'TrashOperation' in scope`.

- [ ] **Step 5: Implement**

`Packages/OpenCleanKit/Sources/Quarantine/Remover.swift`:

```swift
import Foundation
import Privilege
import RuleKit
import ScanEngine

public struct RemovalRequest: Sendable {
    public let item: ScanItem
    public let rule: Rule

    public init(item: ScanItem, rule: Rule) {
        self.item = item
        self.rule = rule
    }
}

public struct RemovalReport: Sendable {
    public let manifest: SessionManifest

    public init(manifest: SessionManifest) {
        self.manifest = manifest
    }

    public var deletedBytes: Int64 { manifest.deletedBytes }
    public var quarantinedBytes: Int64 { manifest.quarantinedBytes }
    public var skipped: [ManifestEntry] { manifest.skippedEntries }
    public var hadSkips: Bool { !skipped.isEmpty }
}

/// Moves `path` to the Trash and returns where it ended up.
public typealias TrashOperation = @Sendable (String) throws -> String?

/// The only component that removes files. Every item passes `PreDeleteChecker` first;
/// every outcome is written to the session manifest.
public struct Remover: Sendable {
    static let checkpointInterval = 50

    let store: QuarantineStore
    let checker: PreDeleteChecker
    let admin: any AdminExecutor
    let deviceOf: @Sendable (String) -> Int32?
    let trash: TrashOperation

    public static let systemTrash: TrashOperation = { path in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        return resulting?.path
    }

    public init(
        store: QuarantineStore, checker: PreDeleteChecker, admin: any AdminExecutor,
        deviceOf: @escaping @Sendable (String) -> Int32? = { FileStat.of($0)?.device },
        trash: @escaping TrashOperation = Remover.systemTrash
    ) {
        self.store = store
        self.checker = checker
        self.admin = admin
        self.deviceOf = deviceOf
        self.trash = trash
    }

    public func remove(_ requests: [RemovalRequest], now: Date = .now) throws -> RemovalReport {
        var manifest = try store.createSession(now: now)
        let itemsDirectory = store.itemsDirectory(manifest.id)
        let quarantineDevice = deviceOf(itemsDirectory.path)

        // Record intent first: a crash after a move still leaves a restorable entry.
        manifest.entries = requests.enumerated().map { index, request in
            let mode = request.rule.effectiveDeleteMode
            let planned = mode == .quarantine && !request.rule.needs(.admin)
                ? itemsDirectory.appendingPathComponent("\(index)")
                    .appendingPathComponent((request.item.path as NSString).lastPathComponent).path
                : nil
            return ManifestEntry(
                id: index, originalPath: request.item.path, storedPath: planned, size: request.item.size,
                ruleID: request.rule.id, mode: mode, outcome: .pending, reason: nil)
        }
        try store.write(manifest)

        var adminIndices: [Int] = []
        for (index, request) in requests.enumerated() {
            if let reason = checker.check(request.item, rule: request.rule) {
                mark(&manifest, index, .skipped, reason.description)
            } else if request.rule.needs(.admin) {
                adminIndices.append(index)
            } else {
                perform(index, request, &manifest, quarantineDevice: quarantineDevice)
            }
            if (index + 1) % Self.checkpointInterval == 0 { try store.write(manifest) }
        }
        runAdminBatch(adminIndices, requests, &manifest)
        try store.write(manifest)
        return RemovalReport(manifest: manifest)
    }

    private func perform(
        _ index: Int, _ request: RemovalRequest, _ manifest: inout SessionManifest, quarantineDevice: Int32?
    ) {
        let fileManager = FileManager.default
        let path = request.item.path
        do {
            switch request.rule.effectiveDeleteMode {
            case .immediate:
                try fileManager.removeItem(atPath: path)
                mark(&manifest, index, .deleted, nil)
            case .quarantine:
                if let quarantineDevice, deviceOf(path) == quarantineDevice,
                    let stored = manifest.entries[index].storedPath
                {
                    try fileManager.createDirectory(
                        atPath: (stored as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try fileManager.moveItem(atPath: path, toPath: stored)
                    mark(&manifest, index, .quarantined, nil)
                } else {
                    manifest.entries[index].storedPath = try trash(path)
                    mark(&manifest, index, .trashed, nil)
                }
            }
        } catch {
            mark(&manifest, index, .failed, error.localizedDescription)
        }
    }

    private func runAdminBatch(_ indices: [Int], _ requests: [RemovalRequest], _ manifest: inout SessionManifest) {
        var batch: [Int] = []
        var length = 0
        for index in indices {
            let path = requests[index].item.path
            if path.contains("\n") || path.contains("\r") {
                mark(&manifest, index, .skipped, SkipReason.adminUnsupportedPath.description)
                continue
            }
            let quotedLength = AdminCommandBuilder.shellQuote(path).utf8.count + 1
            if length + quotedLength > AdminCommandBuilder.maxCommandLength - 64 {
                mark(&manifest, index, .skipped, SkipReason.adminBatchFull.description)
                continue
            }
            length += quotedLength
            batch.append(index)
        }
        guard !batch.isEmpty else { return }

        let command: String
        do {
            command = try AdminCommandBuilder.removalCommand(paths: batch.map { requests[$0].item.path })
        } catch {
            for index in batch { mark(&manifest, index, .failed, "\(error)") }
            return
        }
        switch admin.runAsAdmin(shellCommand: command) {
        case .succeeded:
            for index in batch {
                if FileStat.of(requests[index].item.path) == nil {
                    mark(&manifest, index, .deleted, nil)
                } else {
                    mark(&manifest, index, .failed, "still present after administrator removal")
                }
            }
        case .cancelled:
            for index in batch { mark(&manifest, index, .skipped, SkipReason.adminCancelled.description) }
        case .failed(let message):
            for index in batch { mark(&manifest, index, .failed, message) }
        }
    }

    private func mark(_ manifest: inout SessionManifest, _ index: Int, _ outcome: EntryOutcome, _ reason: String?) {
        manifest.entries[index].outcome = outcome
        manifest.entries[index].reason = reason
        // A planned stored path is only meaningful if the item actually moved there.
        if outcome == .skipped || outcome == .failed {
            manifest.entries[index].storedPath = nil
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter "QuarantineTests"`
Expected: PASS — store, pre-delete, remover (9) and guard (1) tests.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Packages
git commit -m "feat(quarantine): add remover with admin batching and removal guard test" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Restore, purge and the purge schedule

**Files:**
- Create: `Packages/OpenCleanKit/Sources/Quarantine/RestoreService.swift`
- Create: `Packages/OpenCleanKit/Sources/Quarantine/Purger.swift`
- Create: `Packages/OpenCleanKit/Sources/Quarantine/PurgeSchedule.swift`
- Test: `Packages/OpenCleanKit/Tests/QuarantineTests/RestoreAndPurgeTests.swift`

**Interfaces:**
- Consumes: Task 8 `QuarantineStore`, `SessionManifest`, `SessionListing`, `Date.wholeSeconds`; Task 10 `Remover`, `TrashOperation`, `RemovalRequest`; Task 6 `CommandRunner`, `FakeCommandRunner`.
- Produces:
  - `enum ConflictPolicy: String, CaseIterable { skip, keepBoth = "keep-both", replace }`
  - `struct RestoreSkip: Equatable { path: String; reason: String }`, `struct RestoreReport: Equatable { restored: [String]; skipped: [RestoreSkip] }`
  - `struct RestoreService { init(store:trash:); restore(sessionID:paths:onConflict:) throws -> RestoreReport; static func alternateName(for:) -> String }`
  - `struct Purger { static let retentionRange: ClosedRange<Int>; init(store:); purge(retentionDays:now:) -> [String] }`
  - `struct PurgeSchedule { static let label; init(home:runner:uid:); plistURL; isEnabled; enable(executable:) throws; disable() throws }`, `enum ScheduleError: Error { launchctl(String) }`

- [ ] **Step 1: Write the failing tests**

`Packages/OpenCleanKit/Tests/QuarantineTests/RestoreAndPurgeTests.swift`:

```swift
import Darwin
import Foundation
import RuleKit
import ScanEngine
import Testing
import TestSupport
@testable import Quarantine

struct RestoreAndPurgeTests {
    func quarantine(_ home: TempDirectory, _ paths: [String]) throws -> (QuarantineStore, RemovalReport) {
        let store = QuarantineStore(root: home.url.appendingPathComponent("Quarantine"))
        let checker = PreDeleteChecker(
            denyList: DenyList(home: home.path), processChecker: FakeProcessChecker(), openPaths: [])
        let rule = Rule(id: "r", name: "R", category: .user, explain: "x", paths: ["~/x"], safety: .review)
        let requests = try paths.map { RemovalRequest(item: try #require(ScanItem.snapshot(of: $0, ruleID: "r")), rule: rule) }
        let report = try Remover(store: store, checker: checker, admin: FakeAdminExecutor()).remove(requests)
        return (store, report)
    }

    func fakeTrash(_ home: TempDirectory) throws -> TrashOperation {
        let bin = try home.directory("FakeTrash")
        return { source in
            let destination = bin + "/" + UUID().uuidString
            try FileManager.default.moveItem(atPath: source, toPath: destination)
            return destination
        }
    }

    @Test func restoresBytesPermissionsAndXattrs() throws {
        let home = try TempDirectory()
        let path = try home.file("Downloads/report.bin", bytes: 3_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
        let value = Array("hello".utf8)
        #expect(setxattr(path, "com.openclean.test", value, value.count, 0, XATTR_NOFOLLOW) == 0)

        let (store, report) = try quarantine(home, [path])
        #expect(!FileManager.default.fileExists(atPath: path))
        let restored = try RestoreService(store: store).restore(sessionID: report.manifest.id, onConflict: .skip)

        #expect(restored.restored == [path])
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data(repeating: 0xAB, count: 3_000))
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(perms == 0o640)
        var buffer = [UInt8](repeating: 0, count: 16)
        let length = getxattr(path, "com.openclean.test", &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        #expect(Array(buffer.prefix(max(length, 0))) == value)
        #expect(try store.read(id: report.manifest.id).entries.first?.outcome == .restored)
    }

    @Test func restoresUnusualNames() throws {
        let home = try TempDirectory()
        let names = ["line\nbreak", "emoji 🧹.txt", #"quote'"s"#, "-dash", "spa ce"]
        let paths = try names.map { try home.file("odd/" + $0, bytes: 7) }
        let (store, report) = try quarantine(home, paths)
        let restored = try RestoreService(store: store).restore(sessionID: report.manifest.id, onConflict: .skip)
        #expect(Set(restored.restored) == Set(paths))
        for path in paths { #expect(FileManager.default.fileExists(atPath: path)) }
    }

    @Test func conflictPolicies() throws {
        let home = try TempDirectory()
        let path = try home.file("a/f.txt", bytes: 5)
        let (store, report) = try quarantine(home, [path])
        try home.file("a/f.txt", bytes: 1)

        let skipped = try RestoreService(store: store).restore(sessionID: report.manifest.id, onConflict: .skip)
        #expect(skipped.restored.isEmpty)
        #expect(skipped.skipped.first?.reason == "a file already exists at the original location")

        let both = try RestoreService(store: store).restore(sessionID: report.manifest.id, onConflict: .keepBoth)
        #expect(both.restored == [home.path + "/a/f (restored).txt"])
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func replaceMovesExistingFileToTrashFirst() throws {
        let home = try TempDirectory()
        let path = try home.file("a/f.txt", bytes: 5)
        let (store, report) = try quarantine(home, [path])
        try home.file("a/f.txt", bytes: 1)
        let service = RestoreService(store: store, trash: try fakeTrash(home))
        let result = try service.restore(sessionID: report.manifest.id, onConflict: .replace)
        #expect(result.restored == [path])
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).count == 5)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path + "/FakeTrash").count == 1)
    }

    @Test func restoresOnlySelectedPaths() throws {
        let home = try TempDirectory()
        let a = try home.file("a", bytes: 1)
        let b = try home.file("b", bytes: 1)
        let (store, report) = try quarantine(home, [a, b])
        let result = try RestoreService(store: store).restore(sessionID: report.manifest.id, paths: [b], onConflict: .skip)
        #expect(result.restored == [b])
        #expect(!FileManager.default.fileExists(atPath: a))
    }

    @Test func restoresPendingEntriesAfterCrash() throws {
        let home = try TempDirectory()
        let store = QuarantineStore(root: home.url.appendingPathComponent("Quarantine"))
        var session = try store.createSession()
        let stored = store.itemsDirectory(session.id).appendingPathComponent("0/f.txt").path
        try FileManager.default.createDirectory(
            atPath: (stored as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: stored))
        let original = home.path + "/Downloads/f.txt"
        session.entries = [
            ManifestEntry(
                id: 0, originalPath: original, storedPath: stored, size: 3, ruleID: "r",
                mode: .quarantine, outcome: .pending, reason: nil)
        ]
        try store.write(session)

        let result = try RestoreService(store: store).restore(sessionID: session.id, onConflict: .skip)
        #expect(result.restored == [original])
        #expect(try Data(contentsOf: URL(fileURLWithPath: original)) == Data([1, 2, 3]))
    }

    @Test func missingStoredCopyIsReported() throws {
        let home = try TempDirectory()
        let path = try home.file("a", bytes: 1)
        let (store, report) = try quarantine(home, [path])
        try FileManager.default.removeItem(atPath: try #require(report.manifest.entries.first?.storedPath))
        let result = try RestoreService(store: store).restore(sessionID: report.manifest.id, onConflict: .skip)
        #expect(result.skipped == [RestoreSkip(path: path, reason: "stored copy is missing")])
    }

    @Test func purgesOnlyExpiredSessions() throws {
        let home = try TempDirectory()
        let store = QuarantineStore(root: home.url.appendingPathComponent("Quarantine"))
        let now = Date()
        var old = try store.createSession(now: now.addingTimeInterval(-10 * 86_400))
        let oldStored = store.itemsDirectory(old.id).appendingPathComponent("0/x").path
        try FileManager.default.createDirectory(
            atPath: (oldStored as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data([1]).write(to: URL(fileURLWithPath: oldStored))
        old.entries = [
            ManifestEntry(
                id: 0, originalPath: "/x", storedPath: oldStored, size: 1, ruleID: "r", mode: .quarantine,
                outcome: .quarantined, reason: nil)
        ]
        try store.write(old)
        let recent = try store.createSession(now: now.addingTimeInterval(-86_400))

        let purged = Purger(store: store).purge(retentionDays: 7, now: now)

        #expect(purged == [old.id])
        #expect(!FileManager.default.fileExists(atPath: store.itemsDirectory(old.id).path))
        let reloaded = try store.read(id: old.id)
        #expect(reloaded.entries.first?.outcome == .purged)
        #expect(reloaded.purgedAt == now.wholeSeconds)
        #expect(FileManager.default.fileExists(atPath: store.itemsDirectory(recent.id).path))
        #expect(Purger(store: store).purge(retentionDays: 7, now: now).isEmpty)
    }

    @Test func purgesDamagedSessionsByFolderDate() throws {
        let home = try TempDirectory()
        let store = QuarantineStore(root: home.url.appendingPathComponent("Quarantine"))
        let folder = store.sessionDirectory("broken")
        try FileManager.default.createDirectory(at: store.itemsDirectory("broken"), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: folder.path)
        #expect(Purger(store: store).purge(retentionDays: 7) == ["broken"])
        #expect(!FileManager.default.fileExists(atPath: store.itemsDirectory("broken").path))
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func retentionIsClampedToOneThroughNinety() throws {
        let home = try TempDirectory()
        let store = QuarantineStore(root: home.url.appendingPathComponent("Quarantine"))
        let now = Date()
        let twoDays = try store.createSession(now: now.addingTimeInterval(-2 * 86_400))
        let halfDay = try store.createSession(now: now.addingTimeInterval(-12 * 3_600))
        #expect(Purger(store: store).purge(retentionDays: 0, now: now) == [twoDays.id])
        #expect(FileManager.default.fileExists(atPath: store.itemsDirectory(halfDay.id).path))
    }

    @Test func scheduleWritesLaunchAgentAndBootstrapsIt() throws {
        let home = try TempDirectory()
        let runner = FakeCommandRunner()
        let schedule = PurgeSchedule(home: home.path, runner: runner, uid: 501)
        runner.respond("/bin/launchctl bootstrap gui/501 \(schedule.plistURL.path)")

        try schedule.enable(executable: "/usr/local/bin/openclean")

        #expect(schedule.isEnabled)
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: schedule.plistURL), format: nil) as? [String: Any]
        #expect(plist?["Label"] as? String == "io.github.leoanimesh.openclean.purge")
        #expect(plist?["ProgramArguments"] as? [String] == ["/usr/local/bin/openclean", "purge"])
        #expect(runner.calls.contains(["/bin/launchctl", "bootstrap", "gui/501", schedule.plistURL.path]))

        try schedule.disable()
        #expect(!schedule.isEnabled)
        #expect(runner.calls.last == ["/bin/launchctl", "bootout", "gui/501/io.github.leoanimesh.openclean.purge"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RestoreAndPurgeTests`
Expected: build FAILS — `cannot find 'RestoreService' in scope`, `cannot find 'Purger' in scope`, `cannot find 'PurgeSchedule' in scope`.

- [ ] **Step 3: Implement**

`Packages/OpenCleanKit/Sources/Quarantine/RestoreService.swift`:

```swift
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
```

`Packages/OpenCleanKit/Sources/Quarantine/Purger.swift`:

```swift
import Foundation
import RuleKit

/// Deletes stored copies of sessions older than the retention period. Manifests are kept for History.
public struct Purger: Sendable {
    public static let retentionRange = 1...90
    let store: QuarantineStore

    public init(store: QuarantineStore) {
        self.store = store
    }

    @discardableResult
    public func purge(retentionDays: Int, now: Date = .now) -> [String] {
        let days = min(max(retentionDays, Self.retentionRange.lowerBound), Self.retentionRange.upperBound)
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var purged: [String] = []

        for listing in store.listSessions() {
            switch listing {
            case .ok(var manifest) where manifest.purgedAt == nil && manifest.createdAt < cutoff:
                let items = store.itemsDirectory(manifest.id)
                try? FileManager.default.removeItem(at: items)
                for index in manifest.entries.indices
                where [.quarantined, .pending].contains(manifest.entries[index].outcome)
                    && manifest.entries[index].storedPath?.hasPrefix(items.path) == true
                {
                    manifest.entries[index].outcome = .purged
                }
                manifest.purgedAt = now.wholeSeconds
                if (try? store.write(manifest)) != nil { purged.append(manifest.id) }
            case .damaged(let id, let created) where (created ?? .distantFuture) < cutoff:
                let items = store.itemsDirectory(id)
                if FileStat.of(items.path) != nil, (try? FileManager.default.removeItem(at: items)) != nil {
                    purged.append(id)
                }
            default:
                break
            }
        }
        return purged
    }
}
```

`Packages/OpenCleanKit/Sources/Quarantine/PurgeSchedule.swift`:

```swift
import Darwin
import Foundation
import ProcessKit
import RuleKit

public enum ScheduleError: Error, Equatable {
    case launchctl(String)
}

/// Optional daily purge via a per-user LaunchAgent. Off by default.
public struct PurgeSchedule: Sendable {
    public static let label = "io.github.leoanimesh.openclean.purge"
    let launchAgents: URL
    let runner: any CommandRunner
    let uid: uid_t

    public init(home: String, runner: any CommandRunner = ProcessCommandRunner(), uid: uid_t = getuid()) {
        launchAgents = URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.runner = runner
        self.uid = uid
    }

    public var plistURL: URL { launchAgents.appendingPathComponent(Self.label + ".plist") }
    public var isEnabled: Bool { FileStat.of(plistURL.path) != nil }

    public func enable(executable: String) throws {
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executable, "purge"],
            "StartCalendarInterval": ["Hour": 3, "Minute": 15],
            "RunAtLoad": false,
        ]
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        _ = try? runner.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(Self.label)"])
        let output = try runner.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
        guard output.status == 0 else { throw ScheduleError.launchctl(output.stderrText) }
    }

    public func disable() throws {
        if isEnabled { try FileManager.default.removeItem(at: plistURL) }
        _ = try? runner.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(Self.label)"])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter QuarantineTests`
Expected: PASS — including 11 new restore/purge/schedule tests.

- [ ] **Step 5: Commit**

```bash
git add Packages
git commit -m "feat(quarantine): add restore, retention purge and launch agent schedule" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Full Disk Access detection and rebuild advice

**Files:**
- Modify: `Package.swift` (add `Permissions`, `PermissionsTests`)
- Create: `Packages/OpenCleanKit/Sources/Permissions/FullDiskAccessChecker.swift`
- Create: `Packages/OpenCleanKit/Sources/Permissions/SignatureTracker.swift`
- Test: `Packages/OpenCleanKit/Tests/PermissionsTests/PermissionsTests.swift`

**Interfaces:**
- Consumes: Task 1 `TempDirectory`.
- Produces:
  - `enum FullDiskAccessStatus: String { granted, denied, unknown }`
  - `struct FullDiskAccessChecker { static let settingsURL: URL; init(home:probePaths:); status() -> FullDiskAccessStatus }`
  - `enum AccessAdvice: Equatable { ok, grant, regrantAfterRebuild }`
  - `struct SignatureTracker { init(defaults: UserDefaults, currentSignature: String?); advise(status:) -> AccessAdvice; static func currentCDHash() -> String? }`

- [ ] **Step 1: Add the targets**

Append to `Package.swift` `targets:`:

```swift
        .target(
            name: "Permissions",
            path: "Packages/OpenCleanKit/Sources/Permissions"
        ),
        .testTarget(
            name: "PermissionsTests",
            dependencies: ["Permissions", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/PermissionsTests"
        ),
```

- [ ] **Step 2: Write the failing tests**

`Packages/OpenCleanKit/Tests/PermissionsTests/PermissionsTests.swift`:

```swift
import Foundation
import Testing
import TestSupport
@testable import Permissions

struct PermissionsTests {
    @Test func grantedWhenProtectedFolderIsReadable() throws {
        let home = try TempDirectory()
        try home.file("Library/Safari/Bookmarks.plist", bytes: 1)
        #expect(FullDiskAccessChecker(home: home.path).status() == .granted)
    }

    @Test func deniedWhenProtectedFolderIsUnreadable() throws {
        let home = try TempDirectory()
        let safari = try home.directory("Library/Safari")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: safari)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: safari) }
        #expect(FullDiskAccessChecker(home: home.path).status() == .denied)
    }

    @Test func unknownWhenNoProbeFolderExists() throws {
        let home = try TempDirectory()
        #expect(FullDiskAccessChecker(home: home.path).status() == .unknown)
    }

    @Test func adviceTracksGrantsAcrossRebuilds() {
        let suite = "openclean.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(SignatureTracker(defaults: defaults, currentSignature: "aaa").advise(status: .denied) == .grant)
        #expect(SignatureTracker(defaults: defaults, currentSignature: "aaa").advise(status: .granted) == .ok)
        #expect(SignatureTracker(defaults: defaults, currentSignature: "aaa").advise(status: .denied) == .grant)
        #expect(
            SignatureTracker(defaults: defaults, currentSignature: "bbb").advise(status: .denied)
                == .regrantAfterRebuild)
        #expect(SignatureTracker(defaults: defaults, currentSignature: "bbb").advise(status: .granted) == .ok)
    }

    @Test func settingsURLOpensFullDiskAccessPane() {
        #expect(FullDiskAccessChecker.settingsURL.absoluteString.hasSuffix("Privacy_AllFiles"))
    }

    @Test func currentSignatureLookupDoesNotCrash() {
        _ = SignatureTracker.currentCDHash()
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter PermissionsTests`
Expected: build FAILS — `no such module 'Permissions'`.

- [ ] **Step 4: Implement**

`Packages/OpenCleanKit/Sources/Permissions/FullDiskAccessChecker.swift`:

```swift
import Foundation

public enum FullDiskAccessStatus: String, Sendable {
    case granted, denied, unknown
}

/// Detects Full Disk Access by listing a TCC-protected folder. Never assumes.
public struct FullDiskAccessChecker: Sendable {
    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    let probePaths: [String]

    public init(home: String, probePaths: [String]? = nil) {
        self.probePaths = probePaths ?? [
            home + "/Library/Safari",
            home + "/Library/Containers/com.apple.stocks",
        ]
    }

    public func status() -> FullDiskAccessStatus {
        for path in probePaths where FileManager.default.fileExists(atPath: path) {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: path)
                return .granted
            } catch {
                return .denied
            }
        }
        return .unknown
    }
}
```

`Packages/OpenCleanKit/Sources/Permissions/SignatureTracker.swift`:

```swift
import Foundation
import Security

public enum AccessAdvice: Sendable, Equatable {
    case ok
    case grant
    /// Access was granted to an earlier build; ad-hoc rebuilds change the signature TCC checks.
    case regrantAfterRebuild
}

public struct SignatureTracker: @unchecked Sendable {
    static let key = "fullDiskAccess.lastGrantedSignature"
    let defaults: UserDefaults
    let currentSignature: String?

    public init(defaults: UserDefaults, currentSignature: String?) {
        self.defaults = defaults
        self.currentSignature = currentSignature
    }

    public func advise(status: FullDiskAccessStatus) -> AccessAdvice {
        if status == .granted {
            if let currentSignature { defaults.set(currentSignature, forKey: Self.key) }
            return .ok
        }
        if let last = defaults.string(forKey: Self.key), let currentSignature, last != currentSignature {
            return .regrantAfterRebuild
        }
        return .grant
    }

    /// Hex code-directory hash of the running executable, or nil if unsigned.
    public static func currentCDHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
            let dictionary = info as? [String: Any],
            let unique = dictionary[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter PermissionsTests`
Expected: PASS — 6 tests.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Packages
git commit -m "feat(permissions): detect full disk access and advise re-grant after rebuilds" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 13: OpenCleanKit coordinator, settings and cleanup plan

**Files:**
- Modify: `Package.swift` (add `OpenCleanKit`, `OpenCleanKitTests`)
- Create: `Packages/OpenCleanKit/Sources/OpenCleanKit/Settings.swift`
- Create: `Packages/OpenCleanKit/Sources/OpenCleanKit/RulesLocator.swift`
- Create: `Packages/OpenCleanKit/Sources/OpenCleanKit/RuleCatalog.swift`
- Create: `Packages/OpenCleanKit/Sources/OpenCleanKit/CleanupPlan.swift`
- Create: `Packages/OpenCleanKit/Sources/OpenCleanKit/Coordinator.swift`
- Create: `Packages/OpenCleanKit/Sources/TestSupport/FixtureRules.swift`
- Test: `Packages/OpenCleanKit/Tests/OpenCleanKitTests/CoordinatorTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–12.
- Produces:
  - `struct Settings: Codable, Equatable { retentionDays: Int; advancedEnabled: Bool; excludedPaths: [String]; clampedRetentionDays: Int; init(retentionDays:advancedEnabled:excludedPaths:) }`, `struct SettingsStore { init(url:); load() -> Settings; save(_:) throws }`
  - `enum RulesLocator { static func bundledDirectory(environment:mainBundle:) -> URL? }`
  - `struct LoadedRules { rules: [Rule]; problems: [String] }`, `enum RuleCatalog { static func load(directories: [URL], linter: RuleLinter) -> LoadedRules }`
  - `struct CleanupPlan { requests: [RemovalRequest]; init(result:selectedPaths:); isEmpty; itemCount; immediateRequests; quarantineRequests; adminRequests; immediateBytes; quarantineBytes; totalBytes }`
  - `enum DefaultSelection { static func paths(in: ScanResult) -> Set<String> }`
  - `struct OpenCleanCoordinator { init(home:environment:registry:processChecker:openFiles:admin:fullDiskAccess:trash:); home; paths: AppPaths; registry; bundledRulesDirectory: URL?; settingsStore; store; fullDiskAccessStatus(); makeLinter(); loadRules(includeCaution:) -> LoadedRules; scan(_:settings:progress:) async -> ScanResult; execute(_ plan:) throws -> RemovalReport; history() -> [SessionListing]; restore(sessionID:paths:onConflict:) throws -> RestoreReport; purgeExpired(settings:) -> [String]; purgeSchedule() -> PurgeSchedule }`
  - Environment overrides (development and tests only): `OPENCLEAN_HOME`, `OPENCLEAN_RULES_DIR`.
  - `enum FixtureRules { static let yaml: String; static func writeDirectory(in: TempDirectory) throws -> String }` (TestSupport)

- [ ] **Step 1: Add the targets**

Append to `Package.swift` `targets:`:

```swift
        .target(
            name: "OpenCleanKit",
            dependencies: ["RuleKit", "ScanEngine", "Probes", "Privilege", "Quarantine", "Permissions", "ProcessKit"],
            path: "Packages/OpenCleanKit/Sources/OpenCleanKit"
        ),
        .testTarget(
            name: "OpenCleanKitTests",
            dependencies: ["OpenCleanKit", "RuleKit", "ScanEngine", "Probes", "Quarantine", "Permissions", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/OpenCleanKitTests"
        ),
```

- [ ] **Step 2: Add the shared rule fixture**

`Packages/OpenCleanKit/Sources/TestSupport/FixtureRules.swift`:

```swift
import Foundation

/// A small rule pack used by coordinator, CLI and app-model tests.
public enum FixtureRules {
    public static let yaml = """
        pack: fixture
        version: 1
        rules:
          - id: fixture.caches
            name: Fixture caches
            category: user
            explain: Test caches that apps rebuild.
            paths: ["~/Library/Caches/*"]
            safety: regenerable
          - id: fixture.downloads
            name: Old downloads
            category: user
            explain: Test downloads you may not need.
            paths: ["~/Downloads/*"]
            safety: review
          - id: fixture.risky
            name: Risky files
            category: user
            explain: Test files that need care.
            paths: ["~/Risky/*"]
            safety: caution
        """

    /// Writes `fixture.yaml` into `<dir>/rules` and returns that directory's path.
    public static func writeDirectory(in dir: TempDirectory) throws -> String {
        let rules = try dir.directory("rules")
        try yaml.write(toFile: rules + "/fixture.yaml", atomically: true, encoding: .utf8)
        return rules
    }
}
```

- [ ] **Step 3: Write the failing tests**

`Packages/OpenCleanKit/Tests/OpenCleanKitTests/CoordinatorTests.swift`:

```swift
import Foundation
import Quarantine
import RuleKit
import ScanEngine
import Testing
import TestSupport
@testable import OpenCleanKit

struct CoordinatorTests {
    func coordinator(_ home: TempDirectory, rules: String) -> OpenCleanCoordinator {
        OpenCleanCoordinator(
            home: home.path, environment: ["OPENCLEAN_RULES_DIR": rules], registry: ProbeRegistry([]),
            processChecker: FakeProcessChecker(), openFiles: FakeOpenFiles(), admin: FakeAdminExecutor(),
            fullDiskAccess: { .granted }, trash: { _ in nil })
    }

    @Test func loadsRulesAndHidesCautionUnlessAsked() throws {
        let home = try TempDirectory()
        let subject = coordinator(home, rules: try FixtureRules.writeDirectory(in: home))
        #expect(subject.loadRules(includeCaution: false).rules.map(\.id) == ["fixture.caches", "fixture.downloads"])
        #expect(subject.loadRules(includeCaution: true).rules.count == 3)
        #expect(subject.loadRules(includeCaution: true).problems.isEmpty)
    }

    @Test func skipsInvalidAndDuplicateUserPacks() throws {
        let home = try TempDirectory()
        let subject = coordinator(home, rules: try FixtureRules.writeDirectory(in: home))
        let userRules = subject.paths.userRules.path
        try FileManager.default.createDirectory(atPath: userRules, withIntermediateDirectories: true)
        try """
        pack: evil
        version: 1
        rules:
          - id: evil.docs
            name: Docs
            category: user
            explain: no
            paths: ["~/Documents/*"]
            safety: regenerable
        """.write(toFile: userRules + "/evil.yaml", atomically: true, encoding: .utf8)
        try FixtureRules.yaml.write(toFile: userRules + "/copy.yaml", atomically: true, encoding: .utf8)

        let loaded = subject.loadRules(includeCaution: true)
        #expect(loaded.rules.count == 3)
        #expect(loaded.problems.filter { $0.hasPrefix("Skipped rule pack") }.count == 2)
        #expect(loaded.problems.contains { $0.contains("protected location") })
        #expect(loaded.problems.contains { $0.contains("already defined by another pack") })
    }

    @Test func scanCleanHistoryAndRestoreEndToEnd() async throws {
        let home = try TempDirectory()
        let cache = try home.file("Library/Caches/com.example/blob", bytes: 8_192)
        let download = try home.file("Downloads/old.dmg", bytes: 4_096)
        let subject = coordinator(home, rules: try FixtureRules.writeDirectory(in: home))
        let rules = subject.loadRules(includeCaution: false).rules

        let result = await subject.scan(rules, settings: Settings())
        let defaults = DefaultSelection.paths(in: result)
        #expect(defaults == [home.path + "/Library/Caches/com.example"])

        let plan = CleanupPlan(result: result, selectedPaths: defaults.union([download]))
        #expect(plan.itemCount == 2)
        #expect(plan.immediateBytes >= 8_192)
        #expect(plan.quarantineBytes >= 4_096)

        let report = try subject.execute(plan)
        #expect(!FileManager.default.fileExists(atPath: cache))
        #expect(!FileManager.default.fileExists(atPath: download))
        #expect(!report.hadSkips)

        #expect(subject.history().count == 1)
        let restored = try subject.restore(sessionID: report.manifest.id, onConflict: .skip)
        #expect(restored.restored == [download])
        #expect(FileManager.default.fileExists(atPath: download))
    }

    @Test func honoursExcludedPathsFromSettings() async throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/keep/f", bytes: 10)
        try home.file("Library/Caches/drop/f", bytes: 10)
        let subject = coordinator(home, rules: try FixtureRules.writeDirectory(in: home))
        let rules = subject.loadRules(includeCaution: false).rules
        let result = await subject.scan(rules, settings: Settings(excludedPaths: ["~/Library/Caches/keep"]))
        #expect(result.rule("fixture.caches")?.items.map(\.path) == [home.path + "/Library/Caches/drop"])
    }

    @Test func planNeverIncludesReportOnlyItems() {
        let rule = Rule(id: "d", name: "D", category: .developer, explain: "x", probe: "p", safety: .review)
        let item = ScanItem.virtual(path: "tmsnapshot://x", ruleID: "d", hint: nil)
        let result = ScanResult(
            rules: [RuleResult(rule: rule, items: [item])], isComplete: true, startedAt: .now, finishedAt: .now)
        #expect(CleanupPlan(result: result, selectedPaths: ["tmsnapshot://x"]).isEmpty)
        #expect(DefaultSelection.paths(in: result).isEmpty)
    }

    @Test func settingsRoundTripAndClampRetention() throws {
        let home = try TempDirectory()
        let store = SettingsStore(url: home.url.appendingPathComponent("settings.json"))
        #expect(store.load() == Settings())
        try store.save(Settings(retentionDays: 500, advancedEnabled: true, excludedPaths: ["~/x"]))
        #expect(store.load() == Settings(retentionDays: 90, advancedEnabled: true, excludedPaths: ["~/x"]))
        try Data(#"{"advancedEnabled": true}"#.utf8).write(to: store.url)
        #expect(store.load() == Settings(retentionDays: 7, advancedEnabled: true, excludedPaths: []))
    }

    @Test func rulesLocatorPrefersEnvironmentDirectoryWithPacks() throws {
        let home = try TempDirectory()
        let rules = try FixtureRules.writeDirectory(in: home)
        let empty = try home.directory("empty")
        #expect(RulesLocator.bundledDirectory(environment: ["OPENCLEAN_RULES_DIR": rules])?.path == rules)
        #expect(RulesLocator.bundledDirectory(environment: ["OPENCLEAN_RULES_DIR": empty])?.path != empty)
    }

    @Test func homeCanBeOverriddenByEnvironment() throws {
        let home = try TempDirectory()
        let subject = OpenCleanCoordinator(home: "/Users/ignored", environment: ["OPENCLEAN_HOME": home.path])
        #expect(subject.home == home.path)
        #expect(subject.paths.support.path.hasPrefix(home.path))
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test --filter OpenCleanKitTests`
Expected: build FAILS — `no such module 'OpenCleanKit'`.

- [ ] **Step 5: Implement**

`Packages/OpenCleanKit/Sources/OpenCleanKit/Settings.swift`:

```swift
import Foundation
import Quarantine

/// User preferences shared by the app and the CLI (`settings.json` in Application Support).
public struct Settings: Codable, Sendable, Equatable {
    public var retentionDays: Int
    public var advancedEnabled: Bool
    public var excludedPaths: [String]

    public init(retentionDays: Int = 7, advancedEnabled: Bool = false, excludedPaths: [String] = []) {
        self.retentionDays = retentionDays
        self.advancedEnabled = advancedEnabled
        self.excludedPaths = excludedPaths
    }

    enum CodingKeys: String, CodingKey { case retentionDays, advancedEnabled, excludedPaths }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 7
        advancedEnabled = try c.decodeIfPresent(Bool.self, forKey: .advancedEnabled) ?? false
        excludedPaths = try c.decodeIfPresent([String].self, forKey: .excludedPaths) ?? []
    }

    public var clampedRetentionDays: Int {
        min(max(retentionDays, Purger.retentionRange.lowerBound), Purger.retentionRange.upperBound)
    }
}

public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> Settings {
        guard let data = try? Data(contentsOf: url),
            var settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        settings.retentionDays = settings.clampedRetentionDays
        return settings
    }

    public func save(_ settings: Settings) throws {
        var clamped = settings
        clamped.retentionDays = settings.clampedRetentionDays
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(clamped).write(to: url, options: .atomic)
    }
}
```

`Packages/OpenCleanKit/Sources/OpenCleanKit/RulesLocator.swift`:

```swift
import Foundation

/// Finds the bundled rule packs:
/// 1. `$OPENCLEAN_RULES_DIR`
/// 2. `OpenClean.app/Contents/Resources/Rules`
/// 3. `<bin>/../share/openclean/rules` (installed CLI)
/// 4. `<repo>/Rules` (development checkout)
public enum RulesLocator {
    public static func bundledDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment, mainBundle: Bundle = .main
    ) -> URL? {
        var candidates: [URL] = []
        if let override = environment["OPENCLEAN_RULES_DIR"] {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let resources = mainBundle.resourceURL {
            candidates.append(resources.appendingPathComponent("Rules", isDirectory: true))
        }
        if let executable = mainBundle.executableURL?.resolvingSymlinksInPath() {
            candidates.append(
                executable.deletingLastPathComponent()
                    .appendingPathComponent("../share/openclean/rules", isDirectory: true).standardizedFileURL)
        }
        // <repo>/Packages/OpenCleanKit/Sources/OpenCleanKit/RulesLocator.swift
        let sourceFile = URL(fileURLWithPath: #filePath)
        candidates.append(
            sourceFile.deletingLastPathComponent()
                .appendingPathComponent("../../../../Rules", isDirectory: true).standardizedFileURL)

        return candidates.first { directory in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.contains { $0.hasSuffix(".yaml") || $0.hasSuffix(".yml") }
        }
    }
}
```

`Packages/OpenCleanKit/Sources/OpenCleanKit/RuleCatalog.swift`:

```swift
import Foundation
import RuleKit

public struct LoadedRules: Sendable {
    public var rules: [Rule]
    /// Human-readable reasons packs were skipped. Shown as a banner (app) or on stderr (CLI).
    public var problems: [String]

    public init(rules: [Rule] = [], problems: [String] = []) {
        self.rules = rules
        self.problems = problems
    }
}

public enum RuleCatalog {
    /// Loads packs directory by directory. A pack with any lint issue, or reusing an id from an
    /// earlier pack, is skipped whole; other packs still load.
    public static func load(directories: [URL], linter: RuleLinter) -> LoadedRules {
        var loaded = LoadedRules()
        var knownIDs = Set<String>()
        let loader = RulePackLoader()

        for directory in directories {
            let (packs, errors) = loader.loadDirectory(directory)
            loaded.problems += errors.map(\.description)
            for pack in packs {
                var issues = linter.lint([pack]).map(\.description)
                issues += pack.rules.map(\.id).filter { knownIDs.contains($0) }.map {
                    "\(pack.pack) [\($0)]: rule id already defined by another pack"
                }
                if issues.isEmpty {
                    loaded.rules += pack.rules
                    knownIDs.formUnion(pack.rules.map(\.id))
                } else {
                    loaded.problems.append("Skipped rule pack \(pack.sourcePath ?? pack.pack):")
                    loaded.problems += issues.map { "  " + $0 }
                }
            }
        }
        return loaded
    }
}
```

`Packages/OpenCleanKit/Sources/OpenCleanKit/CleanupPlan.swift`:

```swift
import Foundation
import Quarantine
import RuleKit
import ScanEngine

/// What will happen if the user confirms: selected, removable items grouped by delete mode.
public struct CleanupPlan: Sendable {
    public let requests: [RemovalRequest]

    public init(result: ScanResult, selectedPaths: Set<String>) {
        requests = result.rules.flatMap { ruleResult in
            ruleResult.items
                .filter { !$0.reportOnly && selectedPaths.contains($0.path) }
                .map { RemovalRequest(item: $0, rule: ruleResult.rule) }
        }
    }

    public var isEmpty: Bool { requests.isEmpty }
    public var itemCount: Int { requests.count }
    public var immediateRequests: [RemovalRequest] { requests.filter { $0.rule.effectiveDeleteMode == .immediate } }
    public var quarantineRequests: [RemovalRequest] { requests.filter { $0.rule.effectiveDeleteMode == .quarantine } }
    public var adminRequests: [RemovalRequest] { requests.filter { $0.rule.needs(.admin) } }
    public var immediateBytes: Int64 { immediateRequests.reduce(0) { $0 + $1.item.size } }
    public var quarantineBytes: Int64 { quarantineRequests.reduce(0) { $0 + $1.item.size } }
    public var totalBytes: Int64 { immediateBytes + quarantineBytes }
}

public enum DefaultSelection {
    /// Regenerable items from fully scanned rules. Review and caution items start unselected.
    public static func paths(in result: ScanResult) -> Set<String> {
        Set(
            result.rules
                .filter { $0.rule.safety.isSelectedByDefault && $0.status == .scanned }
                .flatMap(\.items)
                .filter { !$0.reportOnly }
                .map(\.path))
    }
}
```

`Packages/OpenCleanKit/Sources/OpenCleanKit/Coordinator.swift`:

```swift
import Foundation
import Permissions
import Privilege
import Probes
import ProcessKit
import Quarantine
import RuleKit
import ScanEngine

/// The single entry point the app and the CLI use. Holds no mutable state.
public struct OpenCleanCoordinator: Sendable {
    public let home: String
    public let paths: AppPaths
    public let registry: ProbeRegistry
    public let bundledRulesDirectory: URL?
    let processChecker: any ProcessChecker
    let openFiles: any OpenFilesProvider
    let admin: any AdminExecutor
    let accessCheck: @Sendable () -> FullDiskAccessStatus
    let trash: TrashOperation

    public init(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        registry: ProbeRegistry = .standard,
        processChecker: any ProcessChecker = RunningProcessChecker(),
        openFiles: any OpenFilesProvider = LsofOpenFilesProvider(),
        admin: any AdminExecutor = OsascriptAdminExecutor(),
        fullDiskAccess: (@Sendable () -> FullDiskAccessStatus)? = nil,
        trash: @escaping TrashOperation = Remover.systemTrash
    ) {
        let resolvedHome = environment["OPENCLEAN_HOME"] ?? home
        self.home = resolvedHome
        paths = AppPaths.standard(home: resolvedHome)
        self.registry = registry
        bundledRulesDirectory = RulesLocator.bundledDirectory(environment: environment)
        self.processChecker = processChecker
        self.openFiles = openFiles
        self.admin = admin
        accessCheck = fullDiskAccess ?? { FullDiskAccessChecker(home: resolvedHome).status() }
        self.trash = trash
    }

    public var settingsStore: SettingsStore { SettingsStore(url: paths.settingsFile) }
    public var store: QuarantineStore { QuarantineStore(root: paths.quarantine) }

    public func fullDiskAccessStatus() -> FullDiskAccessStatus { accessCheck() }

    public func makeLinter() -> RuleLinter { RuleLinter(home: home, knownProbes: registry.ids) }

    public func loadRules(includeCaution: Bool) -> LoadedRules {
        var directories: [URL] = []
        if let bundledRulesDirectory { directories.append(bundledRulesDirectory) }
        directories.append(paths.userRules)
        var loaded = RuleCatalog.load(directories: directories, linter: makeLinter())
        if bundledRulesDirectory == nil {
            loaded.problems.insert("Bundled rule packs were not found. Reinstall, or set OPENCLEAN_RULES_DIR.", at: 0)
        }
        if !includeCaution { loaded.rules.removeAll { $0.safety == .caution } }
        return loaded
    }

    public func scan(
        _ rules: [Rule], settings: Settings, progress: AsyncStream<ScanProgress>.Continuation? = nil
    ) async -> ScanResult {
        let expander = PathExpander(home: home)
        let excludes = settings.excludedPaths.map { path -> String in
            let expanded = expander.expand(path)
            return realPath(expanded) ?? expanded
        }
        let context = ScanContext(
            home: home, hasFullDiskAccess: accessCheck() == .granted, processChecker: processChecker,
            userExcludes: excludes)
        return await ScanEngine(registry: registry).scan(rules, context: context, progress: progress)
    }

    public func execute(_ plan: CleanupPlan) throws -> RemovalReport {
        let openPaths = try? openFiles.openPaths()
        let checker = PreDeleteChecker(
            denyList: DenyList(home: home), processChecker: processChecker, openPaths: openPaths)
        return try Remover(store: store, checker: checker, admin: admin, trash: trash).remove(plan.requests)
    }

    public func history() -> [SessionListing] { store.listSessions() }

    public func restore(sessionID: String, paths: Set<String>? = nil, onConflict: ConflictPolicy) throws -> RestoreReport {
        try RestoreService(store: store, trash: trash).restore(sessionID: sessionID, paths: paths, onConflict: onConflict)
    }

    @discardableResult
    public func purgeExpired(settings: Settings) -> [String] {
        Purger(store: store).purge(retentionDays: settings.clampedRetentionDays)
    }

    public func purgeSchedule() -> PurgeSchedule { PurgeSchedule(home: home) }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter OpenCleanKitTests`
Expected: PASS — 8 tests.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Packages
git commit -m "feat(kit): add coordinator, settings, rule catalog and cleanup plan" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Bundled v1 rule packs

**Files:**
- Create: `Rules/system.yaml`, `Rules/user-caches.yaml`, `Rules/browsers.yaml`, `Rules/dev-tools.yaml`, `Rules/ai.yaml`, `Rules/mail.yaml`, `Rules/trash.yaml`, `Rules/ios.yaml`
- Test: `Packages/OpenCleanKit/Tests/OpenCleanKitTests/BundledRulesTests.swift`

**Interfaces:**
- Consumes: Task 13 `RulesLocator`, `RuleCatalog`; Task 6 `ProbeRegistry.standard`; Task 3 `RuleLinter`.
- Produces: rule ids used by later tasks and docs: `system.caches`, `system.logs`, `system.diagnostic-reports`, `timemachine.local-snapshots`, `user.app-caches`, `user.logs`, `browsers.safari-cache`, `browsers.chrome-cache`, `browsers.firefox-cache`, `browsers.arc-cache`, `xcode.derived-data`, `xcode.archives`, `xcode.device-support`, `xcode.simulators`, `npm.cache`, `yarn.cache`, `pnpm.store`, `pip.cache`, `cargo.registry-cache`, `gradle.caches`, `cocoapods.cache`, `homebrew.cache`, `docker.disk-image`, `ollama.models`, `lmstudio.models`, `huggingface.hub`, `mail.downloads`, `trash.user`, `ios.backups`.

- [ ] **Step 1: Write the failing test**

`Packages/OpenCleanKit/Tests/OpenCleanKitTests/BundledRulesTests.swift`:

```swift
import Foundation
import Probes
import RuleKit
import ScanEngine
import Testing
@testable import OpenCleanKit

struct BundledRulesTests {
    func load() throws -> LoadedRules {
        let directory = try #require(RulesLocator.bundledDirectory(environment: [:]))
        let linter = RuleLinter(home: "/Users/linttest", knownProbes: ProbeRegistry.standard.ids)
        return RuleCatalog.load(directories: [directory], linter: linter)
    }

    @Test func everyBundledPackLintsClean() throws {
        let loaded = try load()
        #expect(loaded.problems.isEmpty, "\(loaded.problems)")
        #expect(loaded.rules.count == 29)
    }

    @Test func everyCategoryHasRules() throws {
        #expect(Set(try load().rules.map(\.category)) == Set(RuleCategory.allCases))
    }

    @Test func safetyPolicyHolds() throws {
        let rules = try load().rules
        #expect(rules.filter { $0.category == .ai }.allSatisfy { $0.safety == .review })
        #expect(rules.filter { $0.needs(.admin) }.allSatisfy { $0.safety == .regenerable })
        #expect(rules.first { $0.id == "ios.backups" }?.conditions.minAgeDays == 90)
        #expect(rules.first { $0.id == "trash.user" }?.effectiveDeleteMode == .immediate)
        #expect(rules.filter { $0.category == .browsers }.allSatisfy { !$0.conditions.appNotRunning.isEmpty })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BundledRulesTests`
Expected: FAIL — `#require` fails because no `Rules/` directory with packs exists yet.

- [ ] **Step 3: Write the rule packs**

`Rules/system.yaml`:

```yaml
pack: system
version: 1
rules:
  - id: system.caches
    name: System caches
    category: system
    explain: Caches that system services and installed apps rebuild automatically when needed. Apple's own system caches are left alone.
    paths:
      - "/Library/Caches/*"
    exclude:
      - "/Library/Caches/com.apple.*"
    safety: regenerable
    requires: [admin]
  - id: system.logs
    name: Archived system logs
    category: system
    explain: Rotated, compressed log archives. Current logs are not touched.
    paths:
      - "/private/var/log/*.gz"
      - "/private/var/log/*.bz2"
    safety: regenerable
    requires: [admin]
  - id: system.diagnostic-reports
    name: System crash reports
    category: system
    explain: Crash and hang reports macOS already collected. Only useful when sending them to a developer.
    paths:
      - "/Library/Logs/DiagnosticReports/*"
    safety: regenerable
    conditions:
      min_age_days: 7
    requires: [admin]
  - id: timemachine.local-snapshots
    name: Local Time Machine snapshots
    category: system
    explain: Shown for information. macOS deletes local snapshots by itself when it needs the space.
    probe: timemachine.local-snapshots
    safety: review
```

`Rules/user-caches.yaml`:

```yaml
pack: user-caches
version: 1
rules:
  - id: user.app-caches
    name: App caches
    category: user
    explain: Per-app cache folders. Apps recreate them on demand; quit apps first for the best result. iCloud and browser caches are handled separately.
    paths:
      - "~/Library/Caches/*"
    exclude:
      - "~/Library/Caches/com.apple.Safari"
      - "~/Library/Caches/Google"
      - "~/Library/Caches/Firefox"
      - "~/Library/Caches/company.thebrowser.Browser"
      - "~/Library/Caches/Homebrew"
      - "~/Library/Caches/CocoaPods"
      - "~/Library/Caches/pip"
      - "~/Library/Caches/Yarn"
      - "~/Library/Caches/CloudKit"
      - "~/Library/Caches/com.apple.bird"
    safety: regenerable
  - id: user.logs
    name: User logs
    category: user
    explain: Diagnostic logs written by apps. Nothing reads them unless you are troubleshooting.
    paths:
      - "~/Library/Logs/*"
    safety: regenerable
```

`Rules/browsers.yaml`:

```yaml
pack: browsers
version: 1
rules:
  - id: browsers.safari-cache
    name: Safari cache
    category: browsers
    explain: Page resources Safari downloads again when needed. History, cookies, passwords and tabs are not touched.
    paths:
      - "~/Library/Caches/com.apple.Safari/*"
      - "~/Library/Containers/com.apple.Safari/Data/Library/Caches/*"
    safety: regenerable
    conditions:
      app_not_running: com.apple.Safari
    requires: [full_disk_access]
  - id: browsers.chrome-cache
    name: Chrome cache
    category: browsers
    explain: Chrome's disk and code caches for each profile. History, cookies, passwords and extensions are not touched.
    paths:
      - "~/Library/Caches/Google/Chrome/*/Cache"
      - "~/Library/Caches/Google/Chrome/*/Code Cache"
    safety: regenerable
    conditions:
      app_not_running: com.google.Chrome
  - id: browsers.firefox-cache
    name: Firefox cache
    category: browsers
    explain: Firefox's network cache for each profile. History, cookies, passwords and add-ons are not touched.
    paths:
      - "~/Library/Caches/Firefox/Profiles/*/cache2"
    safety: regenerable
    conditions:
      app_not_running: org.mozilla.firefox
  - id: browsers.arc-cache
    name: Arc cache
    category: browsers
    explain: Arc's cache folder. Spaces, history, cookies and passwords are stored elsewhere and are not touched.
    paths:
      - "~/Library/Caches/company.thebrowser.Browser/*"
    safety: regenerable
    conditions:
      app_not_running: company.thebrowser.Browser
```

`Rules/dev-tools.yaml`:

```yaml
pack: dev-tools
version: 1
rules:
  - id: xcode.derived-data
    name: Xcode DerivedData
    category: developer
    explain: Build intermediates and indexes Xcode regenerates on the next build.
    paths:
      - "~/Library/Developer/Xcode/DerivedData/*"
    safety: regenerable
    conditions:
      app_not_running: com.apple.dt.Xcode
  - id: xcode.archives
    name: Xcode archives
    category: developer
    explain: App archives used for App Store submission and crash symbolication. Keep the ones for versions you still support.
    paths:
      - "~/Library/Developer/Xcode/Archives/*"
    safety: review
  - id: xcode.device-support
    name: Device support files
    category: developer
    explain: Debug symbols copied from connected devices. Xcode copies them again the next time you connect that device, which can take a few minutes.
    paths:
      - "~/Library/Developer/Xcode/iOS DeviceSupport/*"
      - "~/Library/Developer/Xcode/watchOS DeviceSupport/*"
      - "~/Library/Developer/Xcode/tvOS DeviceSupport/*"
    safety: review
    conditions:
      app_not_running: com.apple.dt.Xcode
  - id: xcode.simulators
    name: Unavailable simulators
    category: developer
    explain: Simulator devices for runtimes that are no longer installed. They cannot be booted.
    probe: xcode.simulators
    safety: review
    conditions:
      app_not_running: com.apple.iphonesimulator
  - id: npm.cache
    name: npm cache
    category: developer
    explain: npm's package download cache. npm downloads packages again when needed.
    paths:
      - "~/.npm/_cacache"
    safety: regenerable
  - id: yarn.cache
    name: Yarn cache
    category: developer
    explain: Yarn's package download cache. Yarn downloads packages again when needed.
    paths:
      - "~/Library/Caches/Yarn/*"
    safety: regenerable
  - id: pnpm.store
    name: pnpm store
    category: developer
    explain: pnpm's shared package store. Existing node_modules keep their own copies; pnpm downloads packages again on the next install.
    paths:
      - "~/Library/pnpm/store/*"
    safety: regenerable
  - id: pip.cache
    name: pip cache
    category: developer
    explain: pip's download and wheel cache. pip downloads packages again when needed.
    paths:
      - "~/Library/Caches/pip/*"
    safety: regenerable
  - id: cargo.registry-cache
    name: Cargo registry cache
    category: developer
    explain: Downloaded crate archives. Cargo downloads them again on the next build that needs them.
    paths:
      - "~/.cargo/registry/cache/*"
    safety: regenerable
  - id: gradle.caches
    name: Gradle caches
    category: developer
    explain: Gradle's dependency and build caches. Gradle rebuilds them on the next build.
    paths:
      - "~/.gradle/caches/*"
    safety: regenerable
  - id: cocoapods.cache
    name: CocoaPods cache
    category: developer
    explain: Downloaded pod sources. CocoaPods downloads them again on the next pod install.
    paths:
      - "~/Library/Caches/CocoaPods/*"
    safety: regenerable
  - id: homebrew.cache
    name: Homebrew downloads
    category: developer
    explain: Bottles and source archives Homebrew keeps after installing. Equivalent to brew cleanup --prune=all.
    probe: homebrew.cache
    safety: regenerable
  - id: docker.disk-image
    name: Docker disk image
    category: developer
    explain: Shows how much space Docker Desktop's virtual disk uses. OpenClean never deletes Docker data; use Docker's own tools.
    probe: docker.disk-image
    safety: review
    requires: [full_disk_access]
```

`Rules/ai.yaml`:

```yaml
pack: ai
version: 1
rules:
  - id: ollama.models
    name: Ollama models
    category: ai
    explain: Models downloaded by Ollama. Ollama downloads a model again the next time you run it, which can take a long time for large models.
    paths:
      - "~/.ollama/models"
    safety: review
    conditions:
      app_not_running: com.electron.ollama
  - id: lmstudio.models
    name: LM Studio models
    category: ai
    explain: Models downloaded in LM Studio. You can download them again from LM Studio's model browser.
    paths:
      - "~/.lmstudio/models/*/*"
      - "~/.cache/lm-studio/models/*/*"
    safety: review
    conditions:
      app_not_running: ai.elementlabs.lmstudio
  - id: huggingface.hub
    name: Hugging Face cache
    category: ai
    explain: Model and dataset files cached by Hugging Face libraries such as transformers and diffusers. They are downloaded again on next use.
    paths:
      - "~/.cache/huggingface/hub/*"
    safety: review
```

`Rules/mail.yaml`:

```yaml
pack: mail
version: 1
rules:
  - id: mail.downloads
    name: Mail attachment copies
    category: mail
    explain: Copies of attachments Mail saved when you opened them. The originals stay in your mailbox.
    paths:
      - "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/*"
    safety: review
    conditions:
      app_not_running: com.apple.mail
    requires: [full_disk_access]
```

`Rules/trash.yaml`:

```yaml
pack: trash
version: 1
rules:
  - id: trash.user
    name: Trash
    category: trash
    explain: Items you already moved to the Trash. Removing them is the same as Empty Trash and cannot be undone.
    paths:
      - "~/.Trash/*"
    safety: review
    delete_mode: immediate
    requires: [full_disk_access]
```

`Rules/ios.yaml`:

```yaml
pack: ios
version: 1
rules:
  - id: ios.backups
    name: Old iPhone and iPad backups
    category: ios
    explain: Local device backups not updated in 90+ days. Make sure you have a newer backup (local or iCloud) before removing one.
    paths:
      - "~/Library/Application Support/MobileSync/Backup/*"
    safety: review
    conditions:
      min_age_days: 90
    requires: [full_disk_access]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BundledRulesTests`
Expected: PASS — 3 tests, 29 rules, no problems.

- [ ] **Step 5: Commit**

```bash
git add Rules Packages
git commit -m "feat(rules): add bundled v1 rule packs" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: CLI — scan, rules and JSON reports

**Files:**
- Modify: `Package.swift` (add swift-argument-parser dependency; `OpenCleanCLI`, `openclean`, `OpenCleanCLITests`)
- Create: `Apps/openclean-cli/Sources/OpenCleanCLI/OpenCleanCommand.swift`
- Create: `Apps/openclean-cli/Sources/OpenCleanCLI/CLISupport.swift`
- Create: `Apps/openclean-cli/Sources/OpenCleanCLI/ScanCommand.swift`
- Create: `Apps/openclean-cli/Sources/OpenCleanCLI/RulesCommand.swift`
- Create: `Apps/openclean-cli/Sources/OpenCleanCLI/JSONReport.swift`
- Create: `Apps/openclean-cli/Sources/OpenCleanCLI/TextReport.swift`
- Create: `Apps/openclean-cli/Sources/openclean/main.swift`
- Create: `Apps/openclean-cli/Tests/OpenCleanCLITests/Support.swift`
- Create: `Apps/openclean-cli/Tests/OpenCleanCLITests/Golden/scan.json`, `Apps/openclean-cli/Tests/OpenCleanCLITests/Golden/history.json` (recorded in Step 5)
- Test: `Apps/openclean-cli/Tests/OpenCleanCLITests/JSONReportTests.swift`, `Apps/openclean-cli/Tests/OpenCleanCLITests/ScanAndRulesCLITests.swift`

**Interfaces:**
- Consumes: Task 13 `OpenCleanCoordinator`, `Settings`, `LoadedRules`, `CleanupPlan`; Task 8/10/11 `SessionListing`, `RemovalReport`, `RestoreReport`; Task 4 `ScanResult`, `RuleScanStatus`.
- Produces:
  - `struct OpenCleanCommand: ParsableCommand { static func execute(arguments: [String]) async -> Int32 }` — maps errors to exit code 1, `ExitCode(n)` to n, help/version to 0.
  - `enum CLI { coordinator(); bootstrap(_:) -> Settings; printError(_:) }`
  - `enum JSONReport { scan(_:), rules(_:), plan(_:), cleanup(_:), history(_:), restore(_:) -> String (throws) }` — all objects carry `"schema": 1`.
  - `enum TextReport { scan(_:), rules(_:), explain(_:), plan(_:retentionDays:), cleanup(_:), history(_:), restore(_:) -> String }`
  - `enum Golden { static func check(_ actual: String, named: String) throws }`, `enum CLIBinary { static func run(_ arguments: [String], environment: [String: String]) throws -> CLIRun }`, `struct CLIRun { status: Int32; stdout: String; stderr: String }`, `enum CLIFixtures { static func home() throws -> (TempDirectory, [String: String]) }` (test support)

- [ ] **Step 1: Add the dependency and targets**

In `Package.swift`, add to `dependencies:`:

```swift
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
```

Append to `targets:`:

```swift
        .target(
            name: "OpenCleanCLI",
            dependencies: [
                "OpenCleanKit", "RuleKit", "ScanEngine", "Quarantine", "Permissions",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Apps/openclean-cli/Sources/OpenCleanCLI"
        ),
        .executableTarget(
            name: "openclean",
            dependencies: ["OpenCleanCLI"],
            path: "Apps/openclean-cli/Sources/openclean"
        ),
        .testTarget(
            name: "OpenCleanCLITests",
            dependencies: ["OpenCleanCLI", "OpenCleanKit", "RuleKit", "ScanEngine", "Quarantine", "TestSupport"],
            path: "Apps/openclean-cli/Tests/OpenCleanCLITests",
            exclude: ["Golden"]
        ),
```

- [ ] **Step 2: Write test support and the failing tests**

`Apps/openclean-cli/Tests/OpenCleanCLITests/Support.swift`:

```swift
import Foundation
import Testing
import TestSupport

/// <repo>/Apps/openclean-cli/Tests/OpenCleanCLITests/Support.swift
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

enum Golden {
    /// Compares against `Golden/<name>`. Run with OPENCLEAN_RECORD_GOLDEN=1 to (re)write the file.
    static func check(_ actual: String, named name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Golden").appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["OPENCLEAN_RECORD_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (actual + "\n").write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        #expect(actual + "\n" == expected, sourceLocation: sourceLocation)
    }
}

struct CLIRun {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum CLIBinary {
    static var url: URL { repoRoot.appendingPathComponent(".build/debug/openclean") }

    /// Runs the built `openclean` binary with stdin closed (never a TTY).
    static func run(_ arguments: [String], environment: [String: String]) throws -> CLIRun {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path + " (run `swift build` first)"])
        }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CLIRun(
            status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self))
    }
}

enum CLIFixtures {
    /// A temp home with the fixture rule pack, plus the environment that points the CLI at it.
    static func home() throws -> (TempDirectory, [String: String]) {
        let home = try TempDirectory()
        let rules = try FixtureRules.writeDirectory(in: home)
        return (home, ["OPENCLEAN_HOME": home.path, "OPENCLEAN_RULES_DIR": rules])
    }

    static func json(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
```

`Apps/openclean-cli/Tests/OpenCleanCLITests/JSONReportTests.swift`:

```swift
import Foundation
import Quarantine
import RuleKit
import ScanEngine
import Testing
@testable import OpenCleanCLI

struct JSONReportTests {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func item(_ path: String, _ rule: String, _ size: Int64, reportOnly: Bool = false, hint: String? = nil) -> ScanItem {
        ScanItem(
            path: path, ruleID: rule, size: size, device: 1, inode: 1, modificationDate: date, ownerUID: 501,
            reportOnly: reportOnly, hint: hint)
    }

    static func scanFixture() -> ScanResult {
        let caches = Rule(
            id: "user.app-caches", name: "App caches", category: .user, explain: "x",
            paths: ["~/Library/Caches/*"], safety: .regenerable)
        let trash = Rule(
            id: "trash.user", name: "Trash", category: .trash, explain: "x", paths: ["~/.Trash/*"],
            safety: .review, requires: [.fullDiskAccess])
        let docker = Rule(
            id: "docker.disk-image", name: "Docker disk image", category: .developer, explain: "x",
            probe: "docker.disk-image", safety: .review)
        return ScanResult(
            rules: [
                RuleResult(rule: caches, items: [
                    item("/Users/t/Library/Caches/com.a", caches.id, 2_048),
                    item("/Users/t/Library/Caches/com.b", caches.id, 1_024),
                ]),
                RuleResult(rule: trash, status: .needsFullDiskAccess),
                RuleResult(
                    rule: docker,
                    items: [item("/Users/t/Docker.raw", docker.id, 4_096, reportOnly: true, hint: "Use docker system prune.")],
                    errors: ["something odd"]),
            ],
            isComplete: true, startedAt: date, finishedAt: date.addingTimeInterval(2))
    }

    static func historyFixture() -> [SessionListing] {
        let manifest = SessionManifest(
            id: "20270115-080000-abcd", createdAt: date, purgedAt: nil,
            entries: [
                ManifestEntry(
                    id: 0, originalPath: "/Users/t/Library/Caches/com.a", storedPath: nil, size: 2_048,
                    ruleID: "user.app-caches", mode: .immediate, outcome: .deleted, reason: nil),
                ManifestEntry(
                    id: 1, originalPath: "/Users/t/Downloads/x.dmg",
                    storedPath: "/Users/t/Library/Application Support/OpenClean/Quarantine/20270115-080000-abcd/items/1/x.dmg",
                    size: 4_096, ruleID: "fixture.downloads", mode: .quarantine, outcome: .quarantined, reason: nil),
                ManifestEntry(
                    id: 2, originalPath: "/Users/t/Library/Caches/com.b", storedPath: nil, size: 1_024,
                    ruleID: "user.app-caches", mode: .immediate, outcome: .skipped, reason: "open in another app"),
            ])
        return [.ok(manifest), .damaged(id: "broken", created: date)]
    }

    @Test func scanJSONMatchesGolden() throws {
        try Golden.check(try JSONReport.scan(Self.scanFixture()), named: "scan.json")
    }

    @Test func scanJSONStructure() throws {
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(try JSONReport.scan(Self.scanFixture()).utf8)) as? [String: Any])
        #expect(json["schema"] as? Int == 1)
        #expect(json["complete"] as? Bool == true)
        #expect(json["totalBytes"] as? Int == 3_072)
        let rules = try #require(json["rules"] as? [[String: Any]])
        #expect(rules.map { $0["id"] as? String } == ["user.app-caches", "trash.user", "docker.disk-image"])
        #expect(rules[1]["status"] as? String == "needs_full_disk_access")
        #expect(rules[2]["totalBytes"] as? Int == 0)
        let dockerItem = try #require((rules[2]["items"] as? [[String: Any]])?.first)
        #expect(dockerItem["reportOnly"] as? Bool == true)
        #expect(dockerItem["bytes"] as? Int == 4_096)
    }

    @Test func historyJSONMatchesGolden() throws {
        try Golden.check(try JSONReport.history(Self.historyFixture()), named: "history.json")
    }

    @Test func historyJSONStructure() throws {
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(try JSONReport.history(Self.historyFixture()).utf8))
                as? [String: Any])
        let sessions = try #require(json["sessions"] as? [[String: Any]])
        #expect(sessions.count == 2)
        #expect(sessions[0]["deletedBytes"] as? Int == 2_048)
        #expect(sessions[0]["quarantinedBytes"] as? Int == 4_096)
        #expect(sessions[0]["skippedCount"] as? Int == 1)
        #expect(sessions[0]["createdAt"] as? String == "2027-01-15T08:00:00Z")
        #expect(sessions[1]["damaged"] as? Bool == true)
    }

    @Test func statusStrings() {
        #expect(JSONReport.status(.scanned) == "scanned")
        #expect(JSONReport.status(.skippedAppRunning("com.x")) == "app_running:com.x")
        #expect(JSONReport.status(.cancelled) == "cancelled")
    }
}
```

`Apps/openclean-cli/Tests/OpenCleanCLITests/ScanAndRulesCLITests.swift`:

```swift
import Foundation
import Testing
import TestSupport

@Suite(.serialized)
struct ScanAndRulesCLITests {
    @Test func scanJSONReportsFixtureRules() throws {
        let (home, env) = try CLIFixtures.home()
        try home.file("Library/Caches/com.example/blob", bytes: 8_192)
        let run = try CLIBinary.run(["scan", "--json"], environment: env)
        #expect(run.status == 0, "\(run.stderr)")
        let json = try CLIFixtures.json(run.stdout)
        #expect((json["totalBytes"] as? Int ?? 0) >= 8_192)
        let ids = (json["rules"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        #expect(ids == ["fixture.caches", "fixture.downloads"])
    }

    @Test func scanTextPrintsTotals() throws {
        let (home, env) = try CLIFixtures.home()
        try home.file("Library/Caches/com.example/blob", bytes: 8_192)
        let run = try CLIBinary.run(["scan"], environment: env)
        #expect(run.status == 0)
        #expect(run.stdout.contains("Fixture caches [fixture.caches]"))
        #expect(run.stdout.contains("Total removable:"))
    }

    @Test func lintAcceptsGoodAndRejectsBadPacks() throws {
        let (home, env) = try CLIFixtures.home()
        let good = try CLIBinary.run(["rules", "lint", home.path + "/rules/fixture.yaml"], environment: env)
        #expect(good.status == 0)
        #expect(good.stdout.hasPrefix("OK: 1 pack(s), 3 rule(s)"))

        let badPath = home.path + "/bad.yaml"
        try "pack: bad\nversion: 1\nrules:\n  - id: bad.docs\n    name: D\n    category: user\n    explain: x\n    paths: [\"~/Documents/*\"]\n    safety: regenerable\n"
            .write(toFile: badPath, atomically: true, encoding: .utf8)
        let bad = try CLIBinary.run(["rules", "lint", badPath], environment: env)
        #expect(bad.status == 1)
        #expect(bad.stderr.contains("protected location"))
    }

    @Test func rulesListAndExplain() throws {
        let (_, env) = try CLIFixtures.home()
        let list = try CLIBinary.run(["rules", "list", "--json"], environment: env)
        #expect(list.status == 0)
        let rules = try CLIFixtures.json(list.stdout)["rules"] as? [[String: Any]]
        #expect(rules?.count == 3)

        let explain = try CLIBinary.run(["rules", "explain", "fixture.downloads"], environment: env)
        #expect(explain.status == 0)
        #expect(explain.stdout.contains("Test downloads you may not need."))

        let unknown = try CLIBinary.run(["rules", "explain", "nope"], environment: env)
        #expect(unknown.status == 1)
    }

    @Test func usageErrorsExitWithOneAndHelpWithZero() throws {
        let (_, env) = try CLIFixtures.home()
        #expect(try CLIBinary.run(["frobnicate"], environment: env).status == 1)
        #expect(try CLIBinary.run(["--help"], environment: env).status == 0)
        #expect(try CLIBinary.run(["--version"], environment: env).stdout.contains("0.1.0"))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift build && swift test --filter OpenCleanCLITests`
Expected: build FAILS — `no such module 'OpenCleanCLI'` (or missing `openclean` sources).

- [ ] **Step 4: Implement**

`Apps/openclean-cli/Sources/openclean/main.swift`:

```swift
import Foundation
import OpenCleanCLI

let status = await OpenCleanCommand.execute(arguments: Array(CommandLine.arguments.dropFirst()))
exit(status)
```

`Apps/openclean-cli/Sources/OpenCleanCLI/OpenCleanCommand.swift`:

```swift
import ArgumentParser
import Foundation

/// Root command. Plain `ParsableCommand`: `execute(arguments:)` dispatches async subcommands itself.
public struct OpenCleanCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "openclean",
        abstract: "Transparent, open-source cleanup for macOS.",
        version: "0.1.0",
        subcommands: [ScanCommand.self, RulesCommand.self]
    )

    public init() {}

    /// Runs the CLI and returns the process exit code:
    /// 0 success (and --help/--version), 1 error or aborted, 2 completed with skipped items.
    public static func execute(arguments: [String]) async -> Int32 {
        do {
            var command = try parseAsRoot(arguments)
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            return 0
        } catch let code as ExitCode {
            return code.rawValue
        } catch {
            if exitCode(for: error) == .success {
                print(fullMessage(for: error))
                return 0
            }
            CLI.printError(fullMessage(for: error))
            return 1
        }
    }
}
```

`Apps/openclean-cli/Sources/OpenCleanCLI/CLISupport.swift`:

```swift
import ArgumentParser
import Foundation
import OpenCleanKit
import Quarantine
import RuleKit

enum CLI {
    static func coordinator() -> OpenCleanCoordinator { OpenCleanCoordinator() }

    /// Loads settings and purges expired quarantine sessions; runs at every invocation.
    static func bootstrap(_ coordinator: OpenCleanCoordinator) -> Settings {
        let settings = coordinator.settingsStore.load()
        coordinator.purgeExpired(settings: settings)
        return settings
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func printProblems(_ problems: [String]) {
        problems.forEach(printError)
    }
}

extension RuleCategory: @retroactive ExpressibleByArgument {}
extension ConflictPolicy: @retroactive ExpressibleByArgument {}
```

`Apps/openclean-cli/Sources/OpenCleanCLI/ScanCommand.swift`:

```swift
import ArgumentParser
import Foundation
import RuleKit

struct ScanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan", abstract: "Find removable files. Nothing is removed.")

    @Option(name: .customLong("category"), help: "Only scan these categories (repeatable).")
    var categories: [RuleCategory] = []

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() async throws {
        let coordinator = CLI.coordinator()
        let settings = CLI.bootstrap(coordinator)
        let loaded = coordinator.loadRules(includeCaution: settings.advancedEnabled)
        CLI.printProblems(loaded.problems)
        let rules = loaded.rules.filter { categories.isEmpty || categories.contains($0.category) }
        let result = await coordinator.scan(rules, settings: settings)
        print(json ? try JSONReport.scan(result) : TextReport.scan(result))
    }
}
```

`Apps/openclean-cli/Sources/OpenCleanCLI/RulesCommand.swift`:

```swift
import ArgumentParser
import Foundation
import RuleKit

struct RulesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules", abstract: "List, check and explain cleanup rules.",
        subcommands: [List.self, Lint.self, Explain.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List every loaded rule.")

        @Flag(help: "Print machine-readable JSON.")
        var json = false

        func run() throws {
            let loaded = CLI.coordinator().loadRules(includeCaution: true)
            CLI.printProblems(loaded.problems)
            print(json ? try JSONReport.rules(loaded.rules) : TextReport.rules(loaded.rules))
        }
    }

    struct Lint: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Validate rule pack files.")

        @Argument(help: "Rule pack YAML files.")
        var files: [String]

        func run() throws {
            let loader = RulePackLoader()
            var packs: [RulePack] = []
            var problems: [String] = []
            for file in files {
                do {
                    packs.append(try loader.load(from: URL(fileURLWithPath: file)))
                } catch {
                    problems.append("\(error)")
                }
            }
            problems += CLI.coordinator().makeLinter().lint(packs).map(\.description)
            guard problems.isEmpty else {
                CLI.printProblems(problems)
                throw ExitCode(1)
            }
            print("OK: \(packs.count) pack(s), \(packs.reduce(0) { $0 + $1.rules.count }) rule(s)")
        }
    }

    struct Explain: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show what a rule removes and why it is safe.")

        @Argument(help: "Rule id, e.g. xcode.derived-data.")
        var ruleID: String

        func run() throws {
            let rules = CLI.coordinator().loadRules(includeCaution: true).rules
            guard let rule = rules.first(where: { $0.id == ruleID }) else {
                throw ValidationError("Unknown rule id '\(ruleID)'. See `openclean rules list`.")
            }
            print(TextReport.explain(rule))
        }
    }
}
```

`Apps/openclean-cli/Sources/OpenCleanCLI/JSONReport.swift`:

```swift
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
```

`Apps/openclean-cli/Sources/OpenCleanCLI/TextReport.swift`:

```swift
import Foundation
import OpenCleanKit
import Quarantine
import RuleKit
import ScanEngine

/// Human-readable output. Not a stable interface; scripts should use --json.
public enum TextReport {
    static func size(_ bytes: Int64) -> String { ByteSize.format(bytes) }

    public static func scan(_ result: ScanResult) -> String {
        var lines: [String] = []
        for (category, rules) in result.categories {
            lines.append(category.displayName)
            for ruleResult in rules {
                let removable = ruleResult.items.filter { !$0.reportOnly }.count
                let detail = ruleResult.status == .scanned
                    ? "\(size(ruleResult.totalSize)) in \(removable) item(s)"
                    : statusText(ruleResult.status)
                lines.append("  \(ruleResult.rule.name) [\(ruleResult.rule.id)]  \(detail)")
                for item in ruleResult.items where item.reportOnly {
                    lines.append("    info: \(item.path)  \(size(item.size))  \(item.hint ?? "")")
                }
            }
        }
        lines.append("")
        lines.append("Total removable: \(size(result.totalSize))")
        if !result.isComplete { lines.append("Scan was cancelled; results are partial.") }
        let needsAccess = result.rules.filter { $0.status == .needsFullDiskAccess }.map(\.rule.id)
        if !needsAccess.isEmpty {
            lines.append("Needs Full Disk Access: \(needsAccess.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    static func statusText(_ status: RuleScanStatus) -> String {
        switch status {
        case .scanned: "scanned"
        case .needsFullDiskAccess: "needs Full Disk Access"
        case .skippedAppRunning(let id): "skipped while \(id) is running"
        case .cancelled: "cancelled"
        }
    }

    public static func rules(_ rules: [Rule]) -> String {
        rules.map { "\($0.id)  [\($0.category.rawValue), \($0.safety.rawValue)]  \($0.name)" }
            .joined(separator: "\n")
    }

    public static func explain(_ rule: Rule) -> String {
        var lines = [
            "\(rule.name) [\(rule.id)]",
            rule.explain,
            "",
            "Category:    \(rule.category.displayName)",
            "Safety:      \(rule.safety.rawValue)",
            "Delete mode: \(rule.effectiveDeleteMode.rawValue)",
        ]
        if let probe = rule.probe { lines.append("Probe:       \(probe)") }
        if !rule.paths.isEmpty { lines.append("Paths:       " + rule.paths.joined(separator: "\n             ")) }
        if !rule.exclude.isEmpty { lines.append("Excludes:    " + rule.exclude.joined(separator: "\n             ")) }
        if !rule.conditions.appNotRunning.isEmpty {
            lines.append("Skipped while running: " + rule.conditions.appNotRunning.joined(separator: ", "))
        }
        if let days = rule.conditions.minAgeDays { lines.append("Only items older than \(days) days") }
        if let minimum = rule.conditions.minSize { lines.append("Only items larger than \(minimum)") }
        if !rule.requires.isEmpty { lines.append("Requires:    " + rule.requires.map(\.rawValue).joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    public static func plan(_ plan: CleanupPlan, retentionDays: Int) -> String {
        var lines = ["Ready to remove \(plan.itemCount) item(s):"]
        lines.append("  Delete now:          \(size(plan.immediateBytes)) (\(plan.immediateRequests.count) items)")
        lines.append(
            "  Move to quarantine:  \(size(plan.quarantineBytes)) (\(plan.quarantineRequests.count) items, restorable for \(retentionDays) days)")
        if !plan.adminRequests.isEmpty {
            lines.append("  \(plan.adminRequests.count) system item(s) need your administrator password.")
        }
        lines.append("Files that changed since the scan or are open in another app are skipped automatically.")
        return lines.joined(separator: "\n")
    }

    public static func cleanup(_ report: RemovalReport) -> String {
        var lines = [
            "Session \(report.manifest.id)",
            "  Freed now:    \(size(report.deletedBytes))",
            "  Quarantined:  \(size(report.quarantinedBytes))  (restore with `openclean restore \(report.manifest.id)`)",
        ]
        if report.hadSkips {
            lines.append("  Skipped \(report.skipped.count) item(s):")
            for entry in report.skipped { lines.append("    \(entry.originalPath): \(entry.reason ?? "unknown reason")") }
        }
        return lines.joined(separator: "\n")
    }

    public static func history(_ listings: [SessionListing]) -> String {
        guard !listings.isEmpty else { return "No cleanup sessions yet." }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return listings.map { listing in
            switch listing {
            case .ok(let manifest):
                let state = manifest.purgedAt == nil ? "" : "  (purged)"
                return "\(manifest.id)  \(formatter.string(from: manifest.createdAt))  freed \(size(manifest.deletedBytes))  quarantined \(size(manifest.quarantinedBytes))  skipped \(manifest.skippedEntries.count)\(state)"
            case .damaged(let id, _):
                return "\(id)  damaged manifest"
            }
        }.joined(separator: "\n")
    }

    public static func restore(_ report: RestoreReport) -> String {
        var lines = ["Restored \(report.restored.count) item(s)."]
        for skip in report.skipped { lines.append("  Skipped \(skip.path): \(skip.reason)") }
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 5: Record the golden files, inspect them, then run all tests**

Run: `swift build && OPENCLEAN_RECORD_GOLDEN=1 swift test --filter JSONReportTests`
Then open `Apps/openclean-cli/Tests/OpenCleanCLITests/Golden/scan.json` and `history.json` and confirm by eye: keys sorted alphabetically, `"schema" : 1`, `"totalBytes" : 3072` in scan.json, the docker item has `"reportOnly" : true` and its `"hint"`, `"needs_full_disk_access"` for trash, and history dates are `"2027-01-15T08:00:00Z"`. These files are the contract for `--json`.

Run: `swift build && swift test --filter OpenCleanCLITests`
Expected: PASS — 5 JSON report tests and 5 CLI tests.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved Apps
git commit -m "feat(cli): add openclean scan and rules commands with versioned JSON output" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: CLI — clean, history, restore, schedule and purge

**Files:**
- Modify: `Apps/openclean-cli/Sources/OpenCleanCLI/OpenCleanCommand.swift` (register new subcommands)
- Create: `Apps/openclean-cli/Sources/OpenCleanCLI/CleanCommand.swift`
- Create: `Apps/openclean-cli/Sources/OpenCleanCLI/CleanSelection.swift`
- Create: `Apps/openclean-cli/Sources/OpenCleanCLI/SessionCommands.swift`
- Test: `Apps/openclean-cli/Tests/OpenCleanCLITests/CleanSelectionTests.swift`, `Apps/openclean-cli/Tests/OpenCleanCLITests/CleanCLITests.swift`

**Interfaces:**
- Consumes: Task 15 `CLI`, `JSONReport`, `TextReport`, `CLIBinary`, `CLIFixtures`; Task 13 `CleanupPlan`, `OpenCleanCoordinator.execute/history/restore/purgeSchedule`.
- Produces:
  - `enum CleanSelection { static func rules(from:categories:ruleIDs:) -> [Rule]; static func paths(in:includeReview:explicitRuleIDs:) -> Set<String> }`
  - Subcommands `clean`, `history`, `restore`, `schedule purge`, hidden `purge`.

- [ ] **Step 1: Write the failing tests**

`Apps/openclean-cli/Tests/OpenCleanCLITests/CleanSelectionTests.swift`:

```swift
import Foundation
import RuleKit
import ScanEngine
import Testing
@testable import OpenCleanCLI

struct CleanSelectionTests {
    let regenerable = Rule(id: "a.regen", name: "A", category: .user, explain: "x", paths: ["~/a/*"], safety: .regenerable)
    let review = Rule(id: "b.review", name: "B", category: .developer, explain: "x", paths: ["~/b/*"], safety: .review)
    let caution = Rule(id: "c.caution", name: "C", category: .user, explain: "x", paths: ["~/c/*"], safety: .caution)

    func result() -> ScanResult {
        func item(_ path: String, _ rule: String) -> ScanItem {
            ScanItem(path: path, ruleID: rule, size: 1, device: 1, inode: 1, modificationDate: .now, ownerUID: 0)
        }
        return ScanResult(
            rules: [
                RuleResult(rule: regenerable, items: [item("/a/1", regenerable.id)]),
                RuleResult(rule: review, items: [item("/b/1", review.id)]),
                RuleResult(rule: caution, items: [item("/c/1", caution.id)]),
            ], isComplete: true, startedAt: .now, finishedAt: .now)
    }

    @Test func rulesFilterByCategoryAndHideCaution() {
        let all = [regenerable, review, caution]
        #expect(CleanSelection.rules(from: all, categories: [], ruleIDs: []).map(\.id) == ["a.regen", "b.review"])
        #expect(CleanSelection.rules(from: all, categories: [.developer], ruleIDs: []).map(\.id) == ["b.review"])
        #expect(CleanSelection.rules(from: all, categories: [], ruleIDs: ["c.caution"]).map(\.id) == ["c.caution"])
    }

    @Test func pathsRespectSafetyFlags() {
        #expect(CleanSelection.paths(in: result(), includeReview: false, explicitRuleIDs: []) == ["/a/1"])
        #expect(CleanSelection.paths(in: result(), includeReview: true, explicitRuleIDs: []) == ["/a/1", "/b/1"])
        #expect(
            CleanSelection.paths(in: result(), includeReview: true, explicitRuleIDs: ["c.caution"])
                == ["/a/1", "/b/1", "/c/1"])
        #expect(CleanSelection.paths(in: result(), includeReview: false, explicitRuleIDs: ["c.caution"]) == ["/a/1"])
    }
}
```

`Apps/openclean-cli/Tests/OpenCleanCLITests/CleanCLITests.swift`:

```swift
import Foundation
import Testing
import TestSupport

@Suite(.serialized)
struct CleanCLITests {
    @Test func dryRunRemovesNothing() throws {
        let (home, env) = try CLIFixtures.home()
        let cache = try home.file("Library/Caches/com.example/blob", bytes: 10)
        let run = try CLIBinary.run(["clean", "--dry-run"], environment: env)
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout.contains("Ready to remove 1 item(s)"))
        #expect(FileManager.default.fileExists(atPath: cache))
    }

    @Test func refusesWithoutConfirmationWhenNotATerminal() throws {
        let (home, env) = try CLIFixtures.home()
        let cache = try home.file("Library/Caches/com.example/blob", bytes: 10)
        let run = try CLIBinary.run(["clean"], environment: env)
        #expect(run.status == 1)
        #expect(run.stderr.contains("--yes"))
        #expect(FileManager.default.fileExists(atPath: cache))
    }

    @Test func yesRemovesRegenerableOnly() throws {
        let (home, env) = try CLIFixtures.home()
        let cache = try home.file("Library/Caches/com.example/blob", bytes: 10)
        let download = try home.file("Downloads/old.dmg", bytes: 10)
        let run = try CLIBinary.run(["clean", "--yes"], environment: env)
        #expect(run.status == 0, "\(run.stderr)")
        #expect(!FileManager.default.fileExists(atPath: cache))
        #expect(FileManager.default.fileExists(atPath: download))
    }

    @Test func includeReviewQuarantinesAndRestoreBringsBack() throws {
        let (home, env) = try CLIFixtures.home()
        let download = try home.file("Downloads/old.dmg", bytes: 10)
        let clean = try CLIBinary.run(["clean", "--yes", "--include-review", "--json"], environment: env)
        #expect(clean.status == 0, "\(clean.stderr)")
        #expect(!FileManager.default.fileExists(atPath: download))
        let session = try #require((try CLIFixtures.json(clean.stdout)["session"] as? [String: Any])?["id"] as? String)

        let history = try CLIBinary.run(["history", "--json"], environment: env)
        let sessions = try CLIFixtures.json(history.stdout)["sessions"] as? [[String: Any]]
        #expect(sessions?.first?["id"] as? String == session)

        let restore = try CLIBinary.run(["restore", session], environment: env)
        #expect(restore.status == 0, "\(restore.stderr)")
        #expect(FileManager.default.fileExists(atPath: download))
    }

    @Test func exitsTwoWhenAnItemIsSkipped() throws {
        let (home, env) = try CLIFixtures.home()
        let file = try home.file("Library/Caches/com.busy/store.db", bytes: 10)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
        defer { try? handle.close() }
        let run = try CLIBinary.run(["clean", "--yes"], environment: env)
        #expect(run.status == 2, "\(run.stdout)\n\(run.stderr)")
        #expect(run.stdout.contains("open in another app"))
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func unknownRuleIDIsAnError() throws {
        let (_, env) = try CLIFixtures.home()
        let run = try CLIBinary.run(["clean", "--rule", "nope", "--dry-run"], environment: env)
        #expect(run.status == 1)
        #expect(run.stderr.contains("Unknown rule id"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift build && swift test --filter "CleanSelectionTests|CleanCLITests"`
Expected: build FAILS — `cannot find 'CleanSelection' in scope`; CLI tests would fail with unknown subcommand `clean`.

- [ ] **Step 3: Implement**

`Apps/openclean-cli/Sources/OpenCleanCLI/CleanSelection.swift`:

```swift
import Foundation
import RuleKit
import ScanEngine

enum CleanSelection {
    /// Rules named with --rule win; otherwise filter by --category and leave out caution rules.
    static func rules(from all: [Rule], categories: Set<RuleCategory>, ruleIDs: Set<String>) -> [Rule] {
        all.filter { rule in
            if !ruleIDs.isEmpty { return ruleIDs.contains(rule.id) }
            return (categories.isEmpty || categories.contains(rule.category)) && rule.safety != .caution
        }
    }

    /// regenerable: always; review: with --include-review; caution: with --include-review AND named by --rule.
    static func paths(in result: ScanResult, includeReview: Bool, explicitRuleIDs: Set<String>) -> Set<String> {
        var selected = Set<String>()
        for ruleResult in result.rules where ruleResult.status == .scanned {
            let allowed: Bool
            switch ruleResult.rule.safety {
            case .regenerable: allowed = true
            case .review: allowed = includeReview
            case .caution: allowed = includeReview && explicitRuleIDs.contains(ruleResult.rule.id)
            }
            if allowed { selected.formUnion(ruleResult.items.filter { !$0.reportOnly }.map(\.path)) }
        }
        return selected
    }
}
```

`Apps/openclean-cli/Sources/OpenCleanCLI/CleanCommand.swift`:

```swift
import ArgumentParser
import Darwin
import Foundation
import OpenCleanKit
import RuleKit

struct CleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean", abstract: "Scan, review and remove selected items.")

    @Option(name: .customLong("category"), help: "Only these categories (repeatable).")
    var categories: [RuleCategory] = []

    @Option(name: .customLong("rule"), help: "Only these rule ids (repeatable). Required to remove caution items.")
    var ruleIDs: [String] = []

    @Flag(name: .customLong("include-review"), help: "Also remove items whose rules are marked review.")
    var includeReview = false

    @Flag(name: .customLong("dry-run"), help: "Show what would be removed, then stop.")
    var dryRun = false

    @Flag(name: [.customLong("yes"), .customShort("y")], help: "Do not ask for confirmation.")
    var yes = false

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() async throws {
        let coordinator = CLI.coordinator()
        let settings = CLI.bootstrap(coordinator)
        let loaded = coordinator.loadRules(includeCaution: true)
        CLI.printProblems(loaded.problems)

        let unknown = Set(ruleIDs).subtracting(loaded.rules.map(\.id))
        guard unknown.isEmpty else {
            throw ValidationError("Unknown rule id(s): \(unknown.sorted().joined(separator: ", "))")
        }

        let rules = CleanSelection.rules(from: loaded.rules, categories: Set(categories), ruleIDs: Set(ruleIDs))
        let result = await coordinator.scan(rules, settings: settings)
        let selected = CleanSelection.paths(in: result, includeReview: includeReview, explicitRuleIDs: Set(ruleIDs))
        let plan = CleanupPlan(result: result, selectedPaths: selected)

        guard !plan.isEmpty else {
            print(json ? try JSONReport.plan(plan) : "Nothing to clean.")
            return
        }
        if json && dryRun {
            print(try JSONReport.plan(plan))
            return
        }
        if !json { print(TextReport.plan(plan, retentionDays: settings.clampedRetentionDays)) }
        if dryRun { return }

        if !yes {
            guard isatty(STDIN_FILENO) == 1 else {
                CLI.printError("Refusing to clean without confirmation. Re-run with --yes.")
                throw ExitCode(1)
            }
            print("Proceed? [y/N] ", terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print("Aborted.")
                throw ExitCode(1)
            }
        }

        let report = try coordinator.execute(plan)
        print(json ? try JSONReport.cleanup(report) : TextReport.cleanup(report))
        if report.hadSkips { throw ExitCode(2) }
    }
}
```

`Apps/openclean-cli/Sources/OpenCleanCLI/SessionCommands.swift`:

```swift
import ArgumentParser
import Foundation
import OpenCleanKit
import Quarantine
import RuleKit

struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "history", abstract: "List past cleanup sessions.")

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        let coordinator = CLI.coordinator()
        _ = CLI.bootstrap(coordinator)
        let listings = coordinator.history()
        print(json ? try JSONReport.history(listings) : TextReport.history(listings))
    }
}

struct RestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore", abstract: "Put quarantined items back where they came from.")

    @Argument(help: "Session id from `openclean history`.")
    var sessionID: String

    @Option(name: .customLong("item"), help: "Only restore these original paths (repeatable).")
    var items: [String] = []

    @Option(name: .customLong("on-conflict"), help: "skip, keep-both or replace when the original path is taken.")
    var onConflict: ConflictPolicy = .skip

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        let coordinator = CLI.coordinator()
        _ = CLI.bootstrap(coordinator)
        let expander = PathExpander(home: coordinator.home)
        let selected = items.isEmpty ? nil : Set(items.map(expander.expand))
        let report = try coordinator.restore(sessionID: sessionID, paths: selected, onConflict: onConflict)
        print(json ? try JSONReport.restore(report) : TextReport.restore(report))
        if !report.skipped.isEmpty { throw ExitCode(2) }
    }
}

struct ScheduleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schedule", abstract: "Manage background tasks.", subcommands: [Purge.self])

    struct Purge: ParsableCommand {
        enum Mode: String, EnumerableFlag {
            case daily, off
        }

        static let configuration = CommandConfiguration(
            commandName: "purge", abstract: "Purge expired quarantine sessions daily (LaunchAgent).")

        @Flag(exclusivity: .exclusive)
        var mode: Mode

        func run() throws {
            let schedule = CLI.coordinator().purgeSchedule()
            switch mode {
            case .daily:
                let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
                try schedule.enable(executable: executable)
                print("Daily purge enabled (\(schedule.plistURL.path)).")
            case .off:
                try schedule.disable()
                print("Daily purge disabled.")
            }
        }
    }
}

/// Run by the LaunchAgent. Hidden from help.
struct PurgeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "purge", abstract: "Remove expired quarantine sessions.", shouldDisplay: false)

    func run() throws {
        let coordinator = CLI.coordinator()
        let settings = coordinator.settingsStore.load()
        let purged = coordinator.purgeExpired(settings: settings)
        print("Purged \(purged.count) session(s).")
    }
}
```

In `Apps/openclean-cli/Sources/OpenCleanCLI/OpenCleanCommand.swift`, change the subcommands line to:

```swift
        subcommands: [
            ScanCommand.self, CleanCommand.self, HistoryCommand.self, RestoreCommand.self,
            RulesCommand.self, ScheduleCommand.self, PurgeCommand.self,
        ]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift build && swift test --filter OpenCleanCLITests`
Expected: PASS — all CLI tests (JSON, scan/rules, selection, clean).

- [ ] **Step 5: Commit**

```bash
git add Apps
git commit -m "feat(cli): add clean, history, restore and purge scheduling commands" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 17: App view model

**Files:**
- Modify: `Package.swift` (add `OpenCleanAppModel`, `OpenCleanAppModelTests`)
- Create: `Apps/OpenClean/Sources/OpenCleanAppModel/AppModel.swift`
- Test: `Apps/OpenClean/Tests/OpenCleanAppModelTests/AppModelTests.swift`

**Interfaces:**
- Consumes: Task 13 `OpenCleanCoordinator`, `Settings`, `LoadedRules`, `CleanupPlan`, `DefaultSelection`; Task 12 `SignatureTracker`, `AccessAdvice`; Task 11 `ConflictPolicy`, `RestoreReport`; Task 8 `SessionListing`; Task 10 `RemovalReport`.
- Produces: `@MainActor @Observable final class AppModel` with
  - state: `phase: Phase (.idle, .scanning, .results, .cleaning, .finished)`, `progress: ScanProgress?`, `result: ScanResult?`, `selectedPaths: Set<String>`, `lastReport: RemovalReport?`, `loadedRules: LoadedRules`, `history: [SessionListing]`, `accessAdvice: AccessAdvice`, `settings: Settings`, `errorMessage: String?`, `isReviewPresented: Bool`, `isErrorPresented: Bool`, `retentionDays: Int`, `advancedEnabled: Bool`, `paths: AppPaths`, `plan: CleanupPlan?`
  - actions: `onLaunch()`, `reloadRules()`, `refreshAccess()`, `refreshHistory()`, `startScan()`, `cancelScan()`, `waitForScan() async`, `clean() async`, `restore(sessionID:paths:onConflict:) async -> RestoreReport?`, `updateSettings(_:)`, `addExclusion(_:)`, `removeExclusion(_:)`
  - selection: `enum CheckState { on, off, mixed }`, `state(of: RuleResult)`, `state(of: RuleCategory)`, `setSelected(_:rule:)`, `setSelected(_:category:)`, `toggle(_ item: ScanItem)`

- [ ] **Step 1: Add the targets**

Append to `Package.swift` `targets:`:

```swift
        .target(
            name: "OpenCleanAppModel",
            dependencies: ["OpenCleanKit", "RuleKit", "ScanEngine", "Quarantine", "Permissions"],
            path: "Apps/OpenClean/Sources/OpenCleanAppModel"
        ),
        .testTarget(
            name: "OpenCleanAppModelTests",
            dependencies: ["OpenCleanAppModel", "OpenCleanKit", "RuleKit", "ScanEngine", "Permissions", "TestSupport"],
            path: "Apps/OpenClean/Tests/OpenCleanAppModelTests"
        ),
```

- [ ] **Step 2: Write the failing tests**

`Apps/OpenClean/Tests/OpenCleanAppModelTests/AppModelTests.swift`:

```swift
import Foundation
import OpenCleanKit
import Permissions
import RuleKit
import ScanEngine
import Testing
import TestSupport
@testable import OpenCleanAppModel

struct SlowAppProbe: Probe {
    static let id = "slow.app-probe"
    func scan(_ context: ScanContext) async throws -> [ProbeFinding] {
        try await Task.sleep(for: .seconds(30))
        return []
    }
}

@MainActor
struct AppModelTests {
    func makeModel(_ home: TempDirectory, registry: ProbeRegistry = ProbeRegistry([])) throws -> AppModel {
        let rules = try FixtureRules.writeDirectory(in: home)
        let coordinator = OpenCleanCoordinator(
            home: home.path, environment: ["OPENCLEAN_RULES_DIR": rules], registry: registry,
            processChecker: FakeProcessChecker(), openFiles: FakeOpenFiles(), admin: FakeAdminExecutor(),
            fullDiskAccess: { .granted }, trash: { _ in nil })
        let defaults = UserDefaults(suiteName: "openclean.appmodel.\(UUID().uuidString)")!
        return AppModel(
            coordinator: coordinator, signatureTracker: SignatureTracker(defaults: defaults, currentSignature: "test"))
    }

    @Test func launchLoadsRulesAccessAndHistory() throws {
        let home = try TempDirectory()
        let model = try makeModel(home)
        model.onLaunch()
        #expect(model.loadedRules.rules.count == 2)
        #expect(model.accessAdvice == .ok)
        #expect(model.history.isEmpty)
        #expect(model.phase == .idle)
    }

    @Test func scanSelectsRegenerableItemsByDefault() async throws {
        let home = try TempDirectory()
        try home.file("Library/Caches/com.example/blob", bytes: 4_096)
        try home.file("Downloads/old.dmg", bytes: 4_096)
        let model = try makeModel(home)
        model.onLaunch()
        model.startScan()
        await model.waitForScan()

        #expect(model.phase == .results)
        #expect(model.selectedPaths == [home.path + "/Library/Caches/com.example"])
        let downloads = try #require(model.result?.rule("fixture.downloads"))
        #expect(model.state(of: downloads) == .off)
        #expect(model.state(of: .user) == .mixed)
        model.setSelected(true, category: .user)
        #expect(model.state(of: .user) == .on)
        model.toggle(try #require(downloads.items.first))
        #expect(model.state(of: downloads) == .off)
    }

    @Test func cleanRemovesSelectionAndRecordsHistory() async throws {
        let home = try TempDirectory()
        let cache = try home.file("Library/Caches/com.example/blob", bytes: 4_096)
        let model = try makeModel(home)
        model.onLaunch()
        model.startScan()
        await model.waitForScan()
        await model.clean()

        #expect(model.phase == .finished)
        #expect(!FileManager.default.fileExists(atPath: cache))
        #expect(model.history.count == 1)
        #expect(model.result?.rule("fixture.caches")?.items.isEmpty == true)
        #expect(model.selectedPaths.isEmpty)
        #expect((model.lastReport?.deletedBytes ?? 0) >= 4_096)
    }

    @Test func restoreFromHistory() async throws {
        let home = try TempDirectory()
        let download = try home.file("Downloads/old.dmg", bytes: 10)
        let model = try makeModel(home)
        model.onLaunch()
        model.startScan()
        await model.waitForScan()
        model.selectedPaths = [download]
        await model.clean()
        #expect(!FileManager.default.fileExists(atPath: download))

        let session = try #require(model.history.first?.id)
        let report = await model.restore(sessionID: session, paths: nil, onConflict: .skip)
        #expect(report?.restored == [download])
        #expect(FileManager.default.fileExists(atPath: download))
    }

    @Test func cancelScanShowsPartialResults() async throws {
        let home = try TempDirectory()
        let model = try makeModel(home, registry: ProbeRegistry([SlowAppProbe()]))
        let userRules = model.paths.userRules.path
        try FileManager.default.createDirectory(atPath: userRules, withIntermediateDirectories: true)
        try """
        pack: slow
        version: 1
        rules:
          - id: slow.rule
            name: Slow
            category: developer
            explain: Takes forever.
            probe: slow.app-probe
            safety: review
        """.write(toFile: userRules + "/slow.yaml", atomically: true, encoding: .utf8)

        model.onLaunch()
        model.startScan()
        try await Task.sleep(for: .milliseconds(150))
        model.cancelScan()
        await model.waitForScan()

        #expect(model.phase == .results)
        #expect(model.result?.isComplete == false)
    }

    @Test func settingsPersistAndAdvancedTogglesCautionRules() throws {
        let home = try TempDirectory()
        let model = try makeModel(home)
        model.onLaunch()
        #expect(model.loadedRules.rules.count == 2)

        model.advancedEnabled = true
        model.retentionDays = 500
        model.addExclusion("/tmp/keep")
        #expect(model.loadedRules.rules.count == 3)
        #expect(model.retentionDays == 90)

        let reloaded = try makeModel(home)
        #expect(reloaded.settings == Settings(retentionDays: 90, advancedEnabled: true, excludedPaths: ["/tmp/keep"]))
        reloaded.removeExclusion("/tmp/keep")
        #expect(reloaded.settings.excludedPaths.isEmpty)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter OpenCleanAppModelTests`
Expected: build FAILS — `no such module 'OpenCleanAppModel'`.

- [ ] **Step 4: Implement**

`Apps/OpenClean/Sources/OpenCleanAppModel/AppModel.swift`:

```swift
import Foundation
import Observation
import OpenCleanKit
import Permissions
import Quarantine
import RuleKit
import ScanEngine

/// All state behind the SwiftUI app. Views read it and call its actions; it never touches files itself.
@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable {
        case idle, scanning, results, cleaning, finished
    }

    public enum CheckState: Equatable {
        case on, off, mixed
    }

    public private(set) var phase: Phase = .idle
    public private(set) var progress: ScanProgress?
    public private(set) var result: ScanResult?
    public var selectedPaths: Set<String> = []
    public private(set) var lastReport: RemovalReport?
    public private(set) var loadedRules = LoadedRules()
    public private(set) var history: [SessionListing] = []
    public private(set) var accessAdvice: AccessAdvice = .ok
    public private(set) var settings: Settings
    public var errorMessage: String?
    public var isReviewPresented = false

    @ObservationIgnored private let coordinator: OpenCleanCoordinator
    @ObservationIgnored private let signatureTracker: SignatureTracker
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    public init(coordinator: OpenCleanCoordinator, signatureTracker: SignatureTracker) {
        self.coordinator = coordinator
        self.signatureTracker = signatureTracker
        settings = coordinator.settingsStore.load()
    }

    public var paths: AppPaths { coordinator.paths }

    public var isErrorPresented: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    // MARK: Lifecycle

    public func onLaunch() {
        coordinator.purgeExpired(settings: settings)
        reloadRules()
        refreshAccess()
        refreshHistory()
    }

    public func reloadRules() {
        loadedRules = coordinator.loadRules(includeCaution: settings.advancedEnabled)
    }

    public func refreshAccess() {
        accessAdvice = signatureTracker.advise(status: coordinator.fullDiskAccessStatus())
    }

    public func refreshHistory() {
        history = coordinator.history()
    }

    // MARK: Scanning

    public func startScan() {
        guard phase != .scanning, phase != .cleaning else { return }
        phase = .scanning
        progress = nil
        result = nil
        lastReport = nil
        let rules = loadedRules.rules
        let settings = settings
        let coordinator = coordinator
        let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)
        scanTask = Task {
            async let scanned = coordinator.scan(rules, settings: settings, progress: continuation)
            for await update in stream {
                self.progress = update
            }
            let finished = await scanned
            self.result = finished
            self.selectedPaths = DefaultSelection.paths(in: finished)
            self.phase = .results
        }
    }

    public func cancelScan() {
        scanTask?.cancel()
    }

    /// Waits for the current scan task (used by tests and the menu command).
    public func waitForScan() async {
        await scanTask?.value
    }

    // MARK: Cleaning

    public var plan: CleanupPlan? {
        result.map { CleanupPlan(result: $0, selectedPaths: selectedPaths) }
    }

    public func clean() async {
        guard let plan, !plan.isEmpty else { return }
        phase = .cleaning
        let coordinator = coordinator
        do {
            let report = try await Task.detached { try coordinator.execute(plan) }.value
            lastReport = report
            dropCleanedItems(report)
            phase = .finished
        } catch {
            errorMessage = error.localizedDescription
            phase = .results
        }
        refreshHistory()
    }

    public func restore(sessionID: String, paths: Set<String>?, onConflict: ConflictPolicy) async -> RestoreReport? {
        let coordinator = coordinator
        do {
            let report = try await Task.detached {
                try coordinator.restore(sessionID: sessionID, paths: paths, onConflict: onConflict)
            }.value
            refreshHistory()
            return report
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func dropCleanedItems(_ report: RemovalReport) {
        let removed = Set(
            report.manifest.entries
                .filter { [.deleted, .quarantined, .trashed].contains($0.outcome) }
                .map(\.originalPath))
        guard var current = result else { return }
        for index in current.rules.indices {
            current.rules[index].items.removeAll { removed.contains($0.path) }
        }
        result = current
        selectedPaths.subtract(removed)
    }

    // MARK: Settings

    public func updateSettings(_ change: (inout Settings) -> Void) {
        let previous = settings
        change(&settings)
        settings.retentionDays = settings.clampedRetentionDays
        do {
            try coordinator.settingsStore.save(settings)
        } catch {
            errorMessage = "Could not save settings: \(error.localizedDescription)"
        }
        if previous.advancedEnabled != settings.advancedEnabled { reloadRules() }
    }

    public var retentionDays: Int {
        get { settings.retentionDays }
        set { updateSettings { $0.retentionDays = newValue } }
    }

    public var advancedEnabled: Bool {
        get { settings.advancedEnabled }
        set { updateSettings { $0.advancedEnabled = newValue } }
    }

    public func addExclusion(_ path: String) {
        updateSettings { settings in
            if !settings.excludedPaths.contains(path) { settings.excludedPaths.append(path) }
        }
    }

    public func removeExclusion(_ path: String) {
        updateSettings { $0.excludedPaths.removeAll { $0 == path } }
    }

    // MARK: Selection

    public func state(of rule: RuleResult) -> CheckState {
        state(for: removable(rule))
    }

    public func state(of category: RuleCategory) -> CheckState {
        state(for: itemsIn(category))
    }

    public func setSelected(_ selected: Bool, rule: RuleResult) {
        apply(selected, to: removable(rule))
    }

    public func setSelected(_ selected: Bool, category: RuleCategory) {
        apply(selected, to: itemsIn(category))
    }

    public func toggle(_ item: ScanItem) {
        guard !item.reportOnly else { return }
        if selectedPaths.contains(item.path) {
            selectedPaths.remove(item.path)
        } else {
            selectedPaths.insert(item.path)
        }
    }

    private func removable(_ rule: RuleResult) -> [ScanItem] {
        rule.items.filter { !$0.reportOnly }
    }

    private func itemsIn(_ category: RuleCategory) -> [ScanItem] {
        (result?.rules ?? []).filter { $0.rule.category == category }.flatMap { removable($0) }
    }

    private func state(for items: [ScanItem]) -> CheckState {
        guard !items.isEmpty else { return .off }
        let selected = items.filter { selectedPaths.contains($0.path) }.count
        if selected == 0 { return .off }
        return selected == items.count ? .on : .mixed
    }

    private func apply(_ selected: Bool, to items: [ScanItem]) {
        let paths = items.map(\.path)
        if selected {
            selectedPaths.formUnion(paths)
        } else {
            selectedPaths.subtract(paths)
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter OpenCleanAppModelTests`
Expected: PASS — 6 tests.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Apps
git commit -m "feat(app): add observable app model for scan, clean, restore and settings" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 18: SwiftUI app screens and the app bundle

**Files:**
- Modify: `Package.swift` (add `OpenCleanApp` executable target)
- Create: `Apps/OpenClean/Info.plist`
- Create: `Makefile`
- Create: `Apps/OpenClean/Sources/OpenCleanApp/OpenCleanApp.swift`
- Create: `Apps/OpenClean/Sources/OpenCleanApp/ContentView.swift`
- Create: `Apps/OpenClean/Sources/OpenCleanApp/Components.swift`
- Create: `Apps/OpenClean/Sources/OpenCleanApp/SmartScanView.swift`
- Create: `Apps/OpenClean/Sources/OpenCleanApp/CleanupView.swift`
- Create: `Apps/OpenClean/Sources/OpenCleanApp/ReviewSheet.swift`
- Create: `Apps/OpenClean/Sources/OpenCleanApp/HistoryView.swift`
- Create: `Apps/OpenClean/Sources/OpenCleanApp/SettingsView.swift`

**Interfaces:**
- Consumes: Task 17 `AppModel` (all members listed there); Task 12 `FullDiskAccessChecker.settingsURL`, `SignatureTracker`; Task 13 `OpenCleanCoordinator`; Task 4 `RuleResult`, `ScanItem`, `ScanResult`; Task 8 `SessionManifest`, `ManifestEntry`, `SessionListing`.
- Produces: `OpenClean.app` via `make app`; `make install`, `make dist`.

All logic is already tested in Task 17; this task is verified by building and by the manual run in Step 5.

- [ ] **Step 1: Add the target, Info.plist and Makefile**

Append to `Package.swift` `targets:`:

```swift
        .executableTarget(
            name: "OpenCleanApp",
            dependencies: ["OpenCleanAppModel", "OpenCleanKit", "RuleKit", "ScanEngine", "Quarantine", "Permissions"],
            path: "Apps/OpenClean/Sources/OpenCleanApp"
        ),
```

`Apps/OpenClean/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>OpenClean</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.leoanimesh.OpenClean</string>
    <key>CFBundleName</key>
    <string>OpenClean</string>
    <key>CFBundleDisplayName</key>
    <string>OpenClean</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 OpenClean contributors. Licensed under GPL-3.0.</string>
</dict>
</plist>
```

`Makefile` (recipe lines start with a tab):

```make
PREFIX ?= /usr/local
VERSION ?= 0.1.0
ARCH_FLAGS ?=
BUILD_DIR := build
APP := $(BUILD_DIR)/OpenClean.app
BIN = $(shell swift build -c release $(ARCH_FLAGS) --show-bin-path)

.PHONY: build test app install uninstall dist lint

build:
	swift build -c release $(ARCH_FLAGS)

test:
	swift test

lint:
	swift format lint --strict --recursive Package.swift Packages Apps
	swift run openclean rules lint Rules/*.yaml

app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources/Rules"
	cp "$(BIN)/OpenCleanApp" "$(APP)/Contents/MacOS/OpenClean"
	cp Apps/OpenClean/Info.plist "$(APP)/Contents/Info.plist"
	cp Rules/*.yaml "$(APP)/Contents/Resources/Rules/"
	codesign --force --sign - "$(APP)"

install: app
	mkdir -p "$(PREFIX)/bin" "$(PREFIX)/share/openclean/rules"
	cp "$(BIN)/openclean" "$(PREFIX)/bin/openclean"
	cp Rules/*.yaml "$(PREFIX)/share/openclean/rules/"
	rm -rf /Applications/OpenClean.app
	cp -R "$(APP)" /Applications/OpenClean.app

uninstall:
	rm -rf /Applications/OpenClean.app "$(PREFIX)/bin/openclean" "$(PREFIX)/share/openclean"

dist: app
	rm -rf "$(BUILD_DIR)/dist"
	mkdir -p "$(BUILD_DIR)/dist/openclean-cli/bin" "$(BUILD_DIR)/dist/openclean-cli/share/openclean/rules"
	cp "$(BIN)/openclean" "$(BUILD_DIR)/dist/openclean-cli/bin/"
	cp Rules/*.yaml "$(BUILD_DIR)/dist/openclean-cli/share/openclean/rules/"
	ditto -c -k --keepParent "$(APP)" "$(BUILD_DIR)/OpenClean-$(VERSION).zip"
	ditto -c -k --keepParent "$(BUILD_DIR)/dist/openclean-cli" "$(BUILD_DIR)/openclean-cli-$(VERSION).zip"
```

- [ ] **Step 2: Write the app shell and shared components**

`Apps/OpenClean/Sources/OpenCleanApp/OpenCleanApp.swift`:

```swift
import AppKit
import OpenCleanAppModel
import OpenCleanKit
import Permissions
import SwiftUI

@main
struct OpenCleanApp: App {
    @State private var model = AppModel(
        coordinator: OpenCleanCoordinator(),
        signatureTracker: SignatureTracker(defaults: .standard, currentSignature: SignatureTracker.currentCDHash()))

    init() {
        // Needed when started with `swift run`; harmless inside OpenClean.app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("OpenClean") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
                .task { model.onLaunch() }
        }
        SwiftUI.Settings {
            SettingsView()
                .environment(model)
                .frame(width: 520)
        }
    }
}
```

`Apps/OpenClean/Sources/OpenCleanApp/Components.swift`:

```swift
import AppKit
import OpenCleanAppModel
import Permissions
import RuleKit
import SwiftUI

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// A tri-state checkbox that announces its state to VoiceOver.
struct CheckboxButton: View {
    let state: AppModel.CheckState
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
                .imageScale(.large)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(state == .on ? "selected" : state == .mixed ? "partially selected" : "not selected")
    }

    private var symbol: String {
        switch state {
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        case .off: "square"
        }
    }
}

struct SafetyBadge: View {
    let safety: SafetyLevel

    var body: some View {
        Text(safety.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("Safety: \(safety.rawValue)")
    }

    private var color: Color {
        switch safety {
        case .regenerable: .green
        case .review: .orange
        case .caution: .red
        }
    }
}

struct AccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.accessAdvice != .ok {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Settings") { NSWorkspace.shared.open(FullDiskAccessChecker.settingsURL) }
                Button("Check Again") { model.refreshAccess() }
            }
            .padding(12)
            .background(Color.yellow.opacity(0.15))
        }
    }

    private var title: String {
        model.accessAdvice == .regrantAfterRebuild
            ? "Full Disk Access needs to be granted again" : "Full Disk Access is off"
    }

    private var message: String {
        model.accessAdvice == .regrantAfterRebuild
            ? "This build of OpenClean has a new signature, so macOS no longer recognises the earlier permission. Remove OpenClean from the list in Settings, add it again, then click Check Again."
            : "Trash, Mail, Safari and iOS backups can only be scanned with Full Disk Access."
    }
}

struct ProblemsBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.loadedRules.problems.isEmpty {
            DisclosureGroup {
                ForEach(model.loadedRules.problems, id: \.self) { problem in
                    Text(problem).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } label: {
                Label("Some rule packs were skipped", systemImage: "exclamationmark.triangle")
            }
            .padding(12)
            .background(Color.orange.opacity(0.12))
        }
    }
}

struct ComingSoonView: View {
    var body: some View {
        ContentUnavailableView(
            "Coming soon", systemImage: "hammer",
            description: Text("This module is planned for a later OpenClean release."))
    }
}
```

`Apps/OpenClean/Sources/OpenCleanApp/ContentView.swift`:

```swift
import OpenCleanAppModel
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case smartScan, cleanup, history, uninstaller, spaceLens, performance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartScan: "Smart Scan"
        case .cleanup: "Cleanup"
        case .history: "History"
        case .uninstaller: "Uninstaller"
        case .spaceLens: "Space Lens"
        case .performance: "Performance"
        }
    }

    var symbol: String {
        switch self {
        case .smartScan: "sparkles"
        case .cleanup: "trash"
        case .history: "clock.arrow.circlepath"
        case .uninstaller: "xmark.app"
        case .spaceLens: "chart.pie"
        case .performance: "speedometer"
        }
    }

    var isAvailable: Bool { [.smartScan, .cleanup, .history].contains(self) }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .smartScan

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(SidebarItem.allCases.filter(\.isAvailable)) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("Coming soon") {
                    ForEach(SidebarItem.allCases.filter { !$0.isAvailable }) { item in
                        Label(item.title, systemImage: item.symbol)
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            VStack(spacing: 0) {
                AccessBanner()
                ProblemsBanner()
                Group {
                    switch selection ?? .smartScan {
                    case .smartScan: SmartScanView()
                    case .cleanup: CleanupView()
                    case .history: HistoryView()
                    default: ComingSoonView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $model.isReviewPresented) { ReviewSheet() }
        .alert("Something went wrong", isPresented: $model.isErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
```

- [ ] **Step 3: Write the screens**

`Apps/OpenClean/Sources/OpenCleanApp/SmartScanView.swift`:

```swift
import OpenCleanAppModel
import Quarantine
import RuleKit
import ScanEngine
import SwiftUI

struct SmartScanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .idle:
            VStack(spacing: 16) {
                Image(systemName: "sparkles").font(.system(size: 56)).foregroundStyle(.tint)
                Text("Smart Scan").font(.largeTitle.bold())
                Text("Finds caches, logs and leftovers you can safely remove. Nothing is removed until you review it.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                Button("Scan") { model.startScan() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(40)
        case .scanning:
            VStack(spacing: 16) {
                ProgressView(value: model.progress?.fraction ?? 0) {
                    Text("Scanning…")
                } currentValueLabel: {
                    Text(model.progress?.ruleID ?? "Starting")
                }
                .frame(maxWidth: 420)
                Button("Cancel") { model.cancelScan() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(40)
        case .results, .cleaning, .finished:
            ResultsSummaryView()
        }
    }
}

struct ResultsSummaryView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let result = model.result, !result.isComplete {
                        Label("The scan was cancelled. Results are partial.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if let report = model.lastReport {
                        CleanupSummary(report: report)
                    }
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.result?.categories ?? [], id: \.category) { entry in
                            CategoryCard(category: entry.category, rules: entry.rules)
                        }
                    }
                }
                .padding(24)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected: \(formatBytes(model.plan?.totalBytes ?? 0))").font(.headline)
                    Text(
                        "\(formatBytes(model.plan?.immediateBytes ?? 0)) freed now · \(formatBytes(model.plan?.quarantineBytes ?? 0)) to quarantine"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if model.phase == .cleaning { ProgressView().controlSize(.small) }
                Button("Scan Again") { model.startScan() }
                    .disabled(model.phase == .cleaning)
                Button("Review & Clean…") { model.isReviewPresented = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.plan?.isEmpty ?? true || model.phase == .cleaning)
            }
            .padding(16)
        }
    }
}

struct CategoryCard: View {
    @Environment(AppModel.self) private var model
    let category: RuleCategory
    let rules: [RuleResult]

    var body: some View {
        let total = rules.reduce(Int64(0)) { $0 + $1.totalSize }
        let count = rules.flatMap(\.items).filter { !$0.reportOnly }.count
        let needsAccess = rules.filter { $0.status == .needsFullDiskAccess }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CheckboxButton(state: model.state(of: category), label: category.displayName) {
                    model.setSelected(model.state(of: category) != .on, category: category)
                }
                Text(category.displayName).font(.headline)
            }
            Text(formatBytes(total)).font(.title2.monospacedDigit())
            Text("\(count) item(s)").foregroundStyle(.secondary)
            if needsAccess > 0 {
                Label("\(needsAccess) rule(s) need Full Disk Access", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CleanupSummary: View {
    let report: RemovalReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Cleanup complete", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
            Text("Freed \(formatBytes(report.deletedBytes)) now · \(formatBytes(report.quarantinedBytes)) in quarantine (see History to restore).")
            if report.hadSkips {
                Text("\(report.skipped.count) item(s) were skipped; details are in History.").foregroundStyle(.secondary)
            }
        }
    }
}
```

`Apps/OpenClean/Sources/OpenCleanApp/CleanupView.swift`:

```swift
import AppKit
import OpenCleanAppModel
import QuickLook
import RuleKit
import ScanEngine
import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var category: RuleCategory?
    @State private var ruleID: String?
    @State private var previewURL: URL?

    var body: some View {
        if let result = model.result {
            HSplitView {
                List(result.categories, id: \.category, selection: $category) { entry in
                    HStack {
                        CheckboxButton(state: model.state(of: entry.category), label: entry.category.displayName) {
                            model.setSelected(model.state(of: entry.category) != .on, category: entry.category)
                        }
                        Text(entry.category.displayName)
                        Spacer()
                        Text(formatBytes(entry.rules.reduce(Int64(0)) { $0 + $1.totalSize }))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 220)

                List(rules(in: result), selection: $ruleID) { rule in
                    HStack {
                        CheckboxButton(state: model.state(of: rule), label: rule.rule.name) {
                            model.setSelected(model.state(of: rule) != .on, rule: rule)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.rule.name)
                            SafetyBadge(safety: rule.rule.safety)
                        }
                        Spacer()
                        Text(detail(for: rule)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 280)

                RuleDetailView(rule: selectedRule(in: result), previewURL: $previewURL)
                    .frame(minWidth: 380)
            }
            .quickLookPreview($previewURL)
        } else {
            ContentUnavailableView(
                "No scan yet", systemImage: "magnifyingglass",
                description: Text("Run Smart Scan to see what can be cleaned."))
        }
    }

    private func rules(in result: ScanResult) -> [RuleResult] {
        let shown = category ?? result.categories.first?.category
        return result.rules.filter { $0.rule.category == shown }
    }

    private func selectedRule(in result: ScanResult) -> RuleResult? {
        if let ruleID, let match = result.rule(ruleID), rules(in: result).contains(where: { $0.id == match.id }) {
            return match
        }
        return rules(in: result).first
    }

    private func detail(for rule: RuleResult) -> String {
        switch rule.status {
        case .scanned: formatBytes(rule.totalSize)
        case .needsFullDiskAccess: "Needs access"
        case .skippedAppRunning: "App running"
        case .cancelled: "Cancelled"
        }
    }
}

struct RuleDetailView: View {
    @Environment(AppModel.self) private var model
    let rule: RuleResult?
    @Binding var previewURL: URL?

    var body: some View {
        if let rule {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(rule.rule.name).font(.title2.bold())
                    SafetyBadge(safety: rule.rule.safety)
                }
                Text(rule.rule.explain)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .skippedAppRunning(let app) = rule.status {
                    Label("Skipped while \(app) is running. Quit it and scan again.", systemImage: "app.badge")
                }
                if rule.status == .needsFullDiskAccess {
                    Label("Grant Full Disk Access to scan this.", systemImage: "lock")
                }
                Table(rule.items) {
                    TableColumn("") { item in
                        CheckboxButton(
                            state: model.selectedPaths.contains(item.path) ? .on : .off,
                            label: (item.path as NSString).lastPathComponent
                        ) { model.toggle(item) }
                        .disabled(item.reportOnly)
                    }
                    .width(28)
                    TableColumn("Item") { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text((item.path as NSString).lastPathComponent)
                            Text(item.hint ?? item.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                            }
                            Button("Quick Look") { previewURL = URL(fileURLWithPath: item.path) }
                        }
                    }
                    TableColumn("Size") { item in
                        Text(formatBytes(item.size)).monospacedDigit()
                    }
                    .width(90)
                }
                if !rule.errors.isEmpty {
                    DisclosureGroup("\(rule.errors.count) note(s)") {
                        ForEach(rule.errors, id: \.self) { note in
                            Text(note).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(16)
        } else {
            ContentUnavailableView("Select a rule", systemImage: "list.bullet")
        }
    }
}
```

`Apps/OpenClean/Sources/OpenCleanApp/ReviewSheet.swift`:

```swift
import OpenCleanAppModel
import SwiftUI

struct ReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review cleanup").font(.title2.bold())
            if let plan = model.plan {
                LabeledContent(
                    "Deleted now", value: "\(formatBytes(plan.immediateBytes)) · \(plan.immediateRequests.count) item(s)")
                LabeledContent(
                    "Moved to quarantine (restorable for \(model.settings.clampedRetentionDays) days)",
                    value: "\(formatBytes(plan.quarantineBytes)) · \(plan.quarantineRequests.count) item(s)")
                if !plan.adminRequests.isEmpty {
                    Label(
                        "\(plan.adminRequests.count) system item(s) need your administrator password.",
                        systemImage: "lock.shield")
                }
                Text("Files that changed since the scan, or are open in another app, are skipped automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Clean") {
                    dismiss()
                    Task { await model.clean() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.plan?.isEmpty ?? true)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
```

`Apps/OpenClean/Sources/OpenCleanApp/HistoryView.swift`:

```swift
import AppKit
import OpenCleanAppModel
import Quarantine
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var pending: PendingRestore?
    @State private var isAsking = false
    @State private var lastRestore: RestoreReport?

    struct PendingRestore {
        let sessionID: String
        let paths: Set<String>?
    }

    var body: some View {
        List {
            if let lastRestore {
                Label(
                    "Restored \(lastRestore.restored.count) item(s), skipped \(lastRestore.skipped.count).",
                    systemImage: "arrow.uturn.backward.circle")
            }
            if model.history.isEmpty {
                ContentUnavailableView("No cleanups yet", systemImage: "clock")
            }
            ForEach(model.history) { listing in
                switch listing {
                case .ok(let manifest):
                    SessionRow(manifest: manifest) { paths in
                        pending = PendingRestore(sessionID: manifest.id, paths: paths)
                        isAsking = true
                    }
                case .damaged(let id, _):
                    HStack {
                        Label("Damaged session \(id)", systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([model.paths.quarantine.appendingPathComponent(id)])
                        }
                    }
                }
            }
        }
        .onAppear { model.refreshHistory() }
        .confirmationDialog("If a file already exists at the original location:", isPresented: $isAsking) {
            Button("Skip It") { restore(.skip) }
            Button("Keep Both") { restore(.keepBoth) }
            Button("Replace It (old one goes to Trash)") { restore(.replace) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func restore(_ policy: ConflictPolicy) {
        guard let pending else { return }
        Task { lastRestore = await model.restore(sessionID: pending.sessionID, paths: pending.paths, onConflict: policy) }
    }
}

struct SessionRow: View {
    let manifest: SessionManifest
    let onRestore: (Set<String>?) -> Void

    var body: some View {
        let restorable = Set(manifest.restorableEntries.map(\.id))
        DisclosureGroup {
            ForEach(manifest.entries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.originalPath).lineLimit(1).truncationMode(.middle)
                        Text([entry.outcome.rawValue.capitalized, entry.reason].compactMap { $0 }.joined(separator: " — "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formatBytes(entry.size)).monospacedDigit().foregroundStyle(.secondary)
                    if manifest.purgedAt == nil && restorable.contains(entry.id) {
                        Button("Restore") { onRestore([entry.originalPath]) }
                    }
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.createdAt, format: .dateTime).font(.headline)
                    Text(
                        "Freed \(formatBytes(manifest.deletedBytes)) · Quarantined \(formatBytes(manifest.quarantinedBytes)) · Skipped \(manifest.skippedEntries.count)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if manifest.purgedAt != nil {
                    Text("Purged").foregroundStyle(.secondary)
                } else if !restorable.isEmpty {
                    Button("Restore All") { onRestore(nil) }
                }
            }
        }
    }
}
```

`Apps/OpenClean/Sources/OpenCleanApp/SettingsView.swift`:

```swift
import AppKit
import OpenCleanAppModel
import Permissions
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Quarantine") {
                Stepper("Keep removed files for \(model.retentionDays) days", value: $model.retentionDays, in: 1...90)
                Text("After this, quarantined files are deleted for good.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Rules") {
                Toggle("Show advanced (caution) rules", isOn: $model.advancedEnabled)
                LabeledContent("Your rule packs") {
                    Button("Reveal in Finder") { revealUserRules() }
                }
            }
            Section("Excluded locations") {
                ForEach(model.settings.excludedPaths, id: \.self) { path in
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Stop Excluding") { model.removeExclusion(path) }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder or File…") { addExclusion() }
            }
            Section("Full Disk Access") {
                LabeledContent("Status", value: model.accessAdvice == .ok ? "Granted" : "Not granted")
                Button("Open Privacy Settings") { NSWorkspace.shared.open(FullDiskAccessChecker.settingsURL) }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func addExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.addExclusion(url.path)
        }
    }

    private func revealUserRules() {
        try? FileManager.default.createDirectory(at: model.paths.userRules, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([model.paths.userRules])
    }
}
```

- [ ] **Step 4: Build the app and run every test**

Run: `swift build && swift test && make app`
Expected: build succeeds with no errors, all tests PASS, and `build/OpenClean.app` exists. `codesign -dv build/OpenClean.app 2>&1 | grep Signature` prints `Signature=adhoc`.

- [ ] **Step 5: Run the app and check it by hand**

Run: `open build/OpenClean.app`
Check, and fix anything that differs:
1. Sidebar shows Smart Scan, Cleanup, History, plus greyed "Coming soon" Uninstaller, Space Lens, Performance that cannot be selected.
2. If Full Disk Access is not granted, the yellow banner appears with Open Settings / Check Again.
3. Smart Scan → Scan shows a progress bar, then category cards with sizes; Developer Tools appears on a Mac with Xcode or npm caches.
4. Cleanup → selecting a category lists its rules; selecting a rule shows its explanation, safety badge and items; right-click an item → Reveal in Finder works.
5. Review & Clean… opens the sheet with "Deleted now" and "Moved to quarantine"; Cancel closes it without removing anything.
6. Settings (⌘,) shows retention stepper, Advanced toggle, excluded locations, Full Disk Access status.
7. Tab and arrow keys reach every control; turn on VoiceOver (⌘F5) and confirm checkboxes read "selected / not selected".

Do not press Clean on your real home folder during this check unless you intend to clean it.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Makefile Apps
git commit -m "feat(app): add SwiftUI screens and ad-hoc signed app bundle" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 19: CI, release workflow, formatting and project docs

**Files:**
- Create: `.swift-format`
- Create: `.github/workflows/ci.yml`, `.github/workflows/release.yml`
- Create: `.github/ISSUE_TEMPLATE/bug_report.yml`, `.github/ISSUE_TEMPLATE/new_rule.yml`
- Modify: `README.md`
- Create: `CONTRIBUTING.md`, `SECURITY.md`, `docs/qa-checklist.md`
- Create: `Formula/openclean.rb` (Homebrew `--HEAD` formula; the repo doubles as a tap)
- Modify: every Swift file reformatted by `swift format`

**Interfaces:**
- Consumes: `make lint`, `make dist`, `openclean rules lint`, all tests.
- Produces: green CI on `main`; tag `v*` publishes `OpenClean-<version>.zip` and `openclean-cli-<version>.zip`.

- [ ] **Step 1: Add the formatter config and format the code**

`.swift-format`:

```json
{
  "version": 1,
  "lineLength": 120,
  "indentation": { "spaces": 4 },
  "respectsExistingLineBreaks": true,
  "lineBreakBeforeEachArgument": false
}
```

Run: `swift format --in-place --recursive Package.swift Packages Apps`
Run: `make lint`
Expected: no `swift format` warnings and `OK: 8 pack(s), 29 rule(s)`. If lint still reports issues, fix them by hand (they are style-only) and re-run until clean.

Run: `swift test`
Expected: PASS (formatting must not change behaviour).

- [ ] **Step 2: Add CI and release workflows**

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  build-test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Toolchain
        run: swift --version
      - name: Build
        run: swift build
      - name: Test
        run: swift test
      - name: Lint code and rule packs
        run: make lint
      - name: Build app bundle
        run: make app
```

`.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags: ["v*"]

permissions:
  contents: write

jobs:
  release:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Test
        run: swift build && swift test
      - name: Build universal app and CLI
        run: make dist VERSION="${GITHUB_REF_NAME#v}" ARCH_FLAGS="--arch arm64 --arch x86_64"
      - name: Publish release
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh release create "$GITHUB_REF_NAME" build/OpenClean-*.zip build/openclean-cli-*.zip --generate-notes
```

- [ ] **Step 3: Add the Homebrew formula**

`Formula/openclean.rb`:

```ruby
class Openclean < Formula
  desc "Transparent, open-source cleanup for macOS"
  homepage "https://github.com/leoAnimesh/OpenClean"
  license "GPL-3.0-only"
  head "https://github.com/leoAnimesh/OpenClean.git", branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on macos: :sonoma

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox", "--product", "openclean"
    bin.install ".build/release/openclean"
    (share/"openclean/rules").install Dir["Rules/*.yaml"]
  end

  test do
    assert_match "0.1.0", shell_output("#{bin}/openclean --version")
  end
end
```

Run: `brew style Formula/openclean.rb`
Expected: no offenses. (A full `brew install --HEAD` test needs the formula pushed; do it after Step 6.)

- [ ] **Step 4: Add issue templates**

`.github/ISSUE_TEMPLATE/bug_report.yml`:

```yaml
name: Bug report
description: Something OpenClean did that it should not have, or did not do.
labels: [bug]
body:
  - type: textarea
    id: what
    attributes:
      label: What happened?
      description: Include the rule id if it is about a specific item (see `openclean rules list`).
    validations:
      required: true
  - type: textarea
    id: expected
    attributes:
      label: What did you expect?
    validations:
      required: true
  - type: input
    id: versions
    attributes:
      label: OpenClean version and macOS version
      placeholder: "0.1.0 on macOS 15.4 (Apple Silicon)"
    validations:
      required: true
  - type: textarea
    id: output
    attributes:
      label: Output
      description: Paste `openclean scan --json` or `openclean history --json` output if relevant. Remove personal paths you do not want to share.
      render: json
```

`.github/ISSUE_TEMPLATE/new_rule.yml`:

```yaml
name: New cleanup rule
description: Propose a cache or leftover OpenClean should know about.
labels: [rule]
body:
  - type: input
    id: app
    attributes:
      label: App or tool
      placeholder: "e.g. JetBrains IDEs"
    validations:
      required: true
  - type: textarea
    id: paths
    attributes:
      label: Paths
      description: Exact folders or globs, e.g. `~/Library/Caches/JetBrains/*`.
    validations:
      required: true
  - type: textarea
    id: safety
    attributes:
      label: Why is it safe to remove?
      description: Does the app rebuild it? Is anything lost (settings, history, downloads)? Link to the app's docs if possible.
    validations:
      required: true
  - type: dropdown
    id: level
    attributes:
      label: Suggested safety level
      options: [regenerable, review, caution]
    validations:
      required: true
```

- [ ] **Step 5: Write the docs**

`README.md`:

````markdown
# OpenClean

Open-source, transparent cleanup for macOS. A community alternative to CleanMyMac.

OpenClean finds caches, logs, developer and AI-tool leftovers you can safely remove, shows you exactly
why each item is safe, and keeps anything that is not trivially regenerable in a quarantine you can
restore from for 7 days.

## Why OpenClean

| CleanMyMac | OpenClean |
|---|---|
| App Store build is sandboxed and asks for folders one by one | Full Disk Access once, plus an admin prompt only for system caches |
| Most removals are permanent | Quarantine with History and Restore |
| Cleaning logic is a black box | Every rule is readable YAML with an explanation, shown in the app |
| Rules come only from the vendor | Community rule packs, linted in CI; add your own |
| Analytics, accounts, upsell | No network access at all |
| GUI only | App and a scriptable CLI with JSON output |
| General junk focus | First-class Xcode, npm, Cargo, Gradle, Docker, Ollama, Hugging Face cleanup |

## Install (build from source)

Requires macOS 14+ and Xcode 16+.

```sh
git clone https://github.com/leoAnimesh/OpenClean.git
cd OpenClean
make install          # app → /Applications, CLI → /usr/local/bin (may need sudo)
```

CLI only, via Homebrew (builds from the latest source):

```sh
brew tap leoanimesh/openclean https://github.com/leoAnimesh/OpenClean
brew install --HEAD openclean
```

Releases on GitHub include an unsigned app zip and the CLI. Because the app is not notarized, right-click
→ Open the first time.

### Full Disk Access

Trash, Mail, Safari and iOS backups live in protected folders. Grant access in
System Settings → Privacy & Security → Full Disk Access. Each rebuild of an unsigned app gets a new
signature, so after updating, remove OpenClean from that list and add it again; the app tells you when.

## Using the CLI

```sh
openclean scan                          # what can be removed, nothing is touched
openclean scan --category developer --json
openclean clean --dry-run               # show the plan
openclean clean --yes                   # remove regenerable items
openclean clean --yes --include-review  # also quarantine review items
openclean history
openclean restore <session-id>
openclean rules list | explain xcode.derived-data | lint my-pack.yaml
openclean schedule purge --daily        # optional daily purge of expired quarantine
```

Exit codes: `0` success, `1` error or aborted, `2` finished but some items were skipped.

## How it stays safe

- A built-in deny-list (System, your Documents/Desktop, Keychains, Mail, iCloud Drive, app bundles,
  Photos libraries) can never be removed, whatever a rule says.
- Symlinks are never followed; a match that resolves outside its rule's folder is dropped.
- Right before removal, items that changed since the scan, are open in another app, or belong to an app
  that is now running are skipped and logged.
- `regenerable` items are deleted; `review` and `caution` items go to quarantine first.
- Only two modules in the codebase can remove files, and a test enforces it.

## Writing rules

See [CONTRIBUTING.md](CONTRIBUTING.md#writing-a-rule). Your own packs go in
`~/Library/Application Support/OpenClean/rules/`.

## Clean-room statement

OpenClean's feature set was informed by inspecting CleanMyMac's App Store bundle metadata and
user-facing strings. No MacPaw code, binaries, rule data or assets were decompiled, copied or used.

## License

GPL-3.0. See [LICENSE](LICENSE).
````

`CONTRIBUTING.md`:

````markdown
# Contributing to OpenClean

## Setup

```sh
swift build
swift test
make lint     # swift format + rule pack lint
make app     # build/OpenClean.app
```

Tests never touch your real home folder: every filesystem test runs in a temporary directory, and the
admin prompt, Trash, lsof and process list are injected. Keep it that way.

## Layout

- `Packages/OpenCleanKit/Sources/` — all logic. No SwiftUI or AppKit here.
- `Apps/openclean-cli` — the `openclean` command.
- `Apps/OpenClean` — the SwiftUI app.
- `Rules/` — bundled rule packs.

Only `Quarantine` and `Privilege` may remove files. `RemovalGuardTests` fails the build otherwise.

## Writing a rule

```yaml
pack: my-tools
version: 1
rules:
  - id: jetbrains.caches
    name: JetBrains IDE caches
    category: developer
    explain: Indexes and caches JetBrains IDEs rebuild when a project is opened.
    paths:
      - "~/Library/Caches/JetBrains/*"
    safety: regenerable
    conditions:
      app_not_running: [com.jetbrains.intellij, com.jetbrains.pycharm]
```

| Field | Notes |
|---|---|
| `id` | Lowercase, dotted, unique: `tool.thing`. |
| `explain` | Required. Say **why** removing it is safe and what the user loses, if anything. |
| `category` | `system`, `user`, `browsers`, `developer`, `ai`, `mail`, `trash`, `ios`. |
| `paths` | Absolute or `~/` globs. `*` matches one level, `**` any depth (not at the end). |
| `safety` | `regenerable` (rebuilt automatically, selected by default, deleted), `review` (user decides, quarantined), `caution` (hidden unless Advanced, quarantined). |
| `conditions` | `app_not_running`, `min_age_days`, `min_size` (e.g. `100MB`). |
| `exclude` | Globs to leave out. |
| `requires` | `full_disk_access`, or `admin` (only for `regenerable` rules). |

Choosing a level: if the app silently rebuilds it and nothing the user made is lost, it is
`regenerable`. If it costs a long re-download (AI models, device symbols) or holds user data
(backups, archives, downloads), it is `review`.

Check your pack with `openclean rules lint path/to/pack.yaml`, then try it with
`openclean scan --json` before opening a pull request.

## Pull requests

- One logical change per PR, with tests.
- `swift test` and `make lint` must pass.
- New behaviour that removes files needs a test showing what is **not** removed.
- Commit messages use Conventional Commits (`feat(scan): …`, `fix(quarantine): …`).
````

`SECURITY.md`:

```markdown
# Security Policy

OpenClean deletes files and can run one command as root (after the macOS administrator prompt), so we
treat the following as security issues:

- Any way to make OpenClean remove a file inside the deny-list, outside a rule's folder, or through a
  symlink.
- Any way to influence the command run with administrator privileges (for example through a crafted
  file name).
- A rule pack that passes `openclean rules lint` but targets user data.

Please report privately via GitHub: **Security → Report a vulnerability** on
https://github.com/leoAnimesh/OpenClean. Do not open a public issue. We aim to reply within 7 days.
```

`docs/qa-checklist.md`:

```markdown
# Manual QA checklist

Run before each release, on a test user account.

## Full Disk Access
- [ ] Fresh install without access: banner says "Full Disk Access is off"; Trash rule shows "Needs access".
- [ ] Grant access, click Check Again: banner disappears; rescanning lists Trash items.
- [ ] Rebuild with `make app`, relaunch: banner says access must be granted again; re-adding OpenClean fixes it.

## Administrator prompt
- [ ] Select System caches, Clean: exactly one administrator prompt appears.
- [ ] Cancel the prompt: those items are listed as skipped in History; everything else was cleaned.
- [ ] Approve the prompt: items are gone and logged as deleted.

## Quarantine and History
- [ ] Clean a review item: it disappears from its folder and appears under History.
- [ ] Restore it: it is back with the same contents; History shows Restored.
- [ ] Restore when a file with the same name exists: the dialog offers Skip / Keep Both / Replace.
- [ ] `openclean schedule purge --daily` creates the LaunchAgent; `--off` removes it.

## Accessibility and appearance
- [ ] Every control reachable with Tab and arrow keys.
- [ ] VoiceOver reads checkbox state ("selected", "partially selected", "not selected") and safety badges.
- [ ] Light and dark mode both readable.
```

- [ ] **Step 6: Verify everything and commit**

Run: `swift build && swift test && make lint && make app`
Expected: all succeed.

```bash
git add -A
git commit -m "chore: add CI, release workflow, formatting and contributor docs" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 7: Push and confirm CI**

```bash
git push origin main
export GH_TOKEN=$(gh auth token --user leoAnimesh)
sleep 10
RUN_ID=$(gh run list --repo leoAnimesh/OpenClean --branch main --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$RUN_ID" --repo leoAnimesh/OpenClean --exit-status
```

Expected: the CI run for the pushed commit finishes green. If it fails, read the log with
`GH_TOKEN=$(gh auth token --user leoAnimesh) gh run view --repo leoAnimesh/OpenClean --log-failed`, fix, and push again.
