import Foundation
import TestSupport
import Testing

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
