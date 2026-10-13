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
        "delete_mode", "conditions", "exclude", "requires", "make_writable",
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
