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
