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
        #expect(loaded.rules.count == 71)
        #expect(
            Set(loaded.rules.map(\.id)) == [
                "system.caches",
                "system.logs",
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
                "npm.npx-cache",
                "bun.cache",
                "deno.cache",
                "yarn.berry-cache",
                "corepack.cache",
                "node-gyp.cache",
                "electron.cache",
                "playwright.browsers",
                "puppeteer.browsers",
                "cypress.cache",
                "uv.cache",
                "poetry.cache",
                "poetry.virtualenvs",
                "conda.package-archives",
                "pre-commit.cache",
                "go.build-cache",
                "cargo.registry-src",
                "cargo.git-checkouts",
                "maven.repository",
                "coursier.cache",
                "ivy.cache",
                "gradle.wrapper-dists",
                "gradle.daemon-logs",
                "swiftpm.cache",
                "dart.pub-cache",
                "bundler.cache",
                "composer.cache",
                "terraform.plugin-cache",
                "jetbrains.indexes",
                "vscode.caches",
                "cursor.caches",
                "unity.cache",
                "node.project-modules",
                "python.project-venvs",
                "rust.project-targets",
                "dev.project-build-outputs",
                "huggingface.datasets",
                "huggingface.xet",
                "torch.hub",
                "whisper.models",
                "keras.cache",
                "tensorflow.datasets",
                "kaggle.cache",
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
        // Anything inside user projects, virtual environments or holding locally built artifacts is quarantined.
        for id in [
            "node.project-modules", "python.project-venvs", "rust.project-targets", "dev.project-build-outputs",
            "poetry.virtualenvs", "maven.repository", "dart.pub-cache", "yarn.berry-cache", "jetbrains.indexes",
            "playwright.browsers", "puppeteer.browsers", "cypress.cache",
        ] {
            #expect(rules.first { $0.id == id }?.safety == .review, "\(id)")
        }
        // Developer caches with their own rule are not also swept up as generic app caches.
        for folder in [
            "deno", "node-gyp", "electron", "electron-builder", "Cypress", "pypoetry", "go-build", "Coursier",
            "org.swift.swiftpm", "composer", "JetBrains", "ms-playwright",
        ] {
            #expect(appCaches.exclude.contains("~/Library/Caches/\(folder)"), "\(folder)")
        }
        #expect(rules.first { $0.id == "deno.cache" }?.exclude == ["~/Library/Caches/deno/location_data"])
    }
}
