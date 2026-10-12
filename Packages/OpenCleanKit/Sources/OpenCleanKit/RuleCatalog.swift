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
