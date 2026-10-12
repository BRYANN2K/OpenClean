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
