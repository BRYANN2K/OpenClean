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
        if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("name is empty")
        }
        if rule.explain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
        if rule.makeWritable {
            if rule.safety != .regenerable {
                problems.append("make_writable is only allowed for regenerable rules")
            }
            if rule.effectiveDeleteMode != .immediate {
                problems.append("make_writable is only allowed for rules that delete immediately")
            }
            if rule.needs(.admin) {
                problems.append("make_writable can't be combined with requires: admin")
            }
        }
        if let days = rule.conditions.minAgeDays, days < 0 {
            problems.append("min_age_days must be >= 0")
        }

        return problems.map { LintIssue(pack: pack, ruleID: rule.id, message: $0) }
    }
}
