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
        #expect(
            Set(loaded.rules.map(\.id)) == [
                "system.caches",
                "system.logs",
                "system.diagnostic-reports",
                "timemachine.local-snapshots",
                "user.app-caches",
                "user.logs",
                "browsers.safari-cache",
                "browsers.chrome-cache",
                "browsers.firefox-cache",
                "browsers.arc-cache",
                "xcode.derived-data",
                "xcode.archives",
                "xcode.device-support",
                "xcode.simulators",
                "npm.cache",
                "yarn.cache",
                "pnpm.store",
                "pip.cache",
                "cargo.registry-cache",
                "gradle.caches",
                "cocoapods.cache",
                "homebrew.cache",
                "docker.disk-image",
                "ollama.models",
                "lmstudio.models",
                "huggingface.hub",
                "mail.downloads",
                "trash.user",
                "ios.backups",
            ])
    }

    @Test func everyCategoryHasRules() throws {
        #expect(Set(try load().rules.map(\.category)) == Set(RuleCategory.allCases))
    }

    @Test func safetyPolicyHolds() throws {
        let rules = try load().rules
        let appCaches = try #require(rules.first { $0.id == "user.app-caches" })
        #expect(appCaches.exclude.contains("~/Library/Caches/com.apple.*"))
        #expect(appCaches.exclude.contains("~/Library/Caches/JetBrains"))
        #expect(rules.filter { $0.category == .ai }.allSatisfy { $0.safety == .review })
        #expect(rules.filter { $0.needs(.admin) }.allSatisfy { $0.safety == .regenerable })
        #expect(rules.first { $0.id == "ios.backups" }?.conditions.minAgeDays == 90)
        #expect(rules.first { $0.id == "trash.user" }?.effectiveDeleteMode == .immediate)
        #expect(rules.filter { $0.category == .browsers }.allSatisfy { !$0.conditions.appNotRunning.isEmpty })
    }
}
