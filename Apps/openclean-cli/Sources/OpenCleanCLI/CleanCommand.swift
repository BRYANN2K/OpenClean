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

    @Flag(
        name: .customLong("allow-admin"),
        help: "Allow system items that need the administrator password when not running in a terminal.")
    var allowAdmin = false

    func run() async throws {
        if json && !dryRun && !yes {
            CLI.printError("--json requires --yes or --dry-run")
            throw ExitCode(1)
        }
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
        var selected = CleanSelection.paths(in: result, includeReview: includeReview, explicitRuleIDs: Set(ruleIDs))
        if isatty(STDIN_FILENO) != 1 && !allowAdmin {
            let filtered = CleanSelection.excludingAdmin(selected, in: result)
            selected = filtered.kept
            if filtered.dropped > 0 {
                CLI.printError(
                    "Skipped \(filtered.dropped) system item(s) that need the administrator password; re-run in a terminal or pass --allow-admin."
                )
            }
        }
        let plan = CleanupPlan(result: result, selectedPaths: selected)

        guard !plan.isEmpty else {
            if json {
                print(try JSONReport.plan(plan))
            } else {
                let held = result.rules.filter { $0.status == .scanned && ($0.rule.safety != .regenerable) }
                    .reduce(0) { $0 + $1.items.filter { !$0.reportOnly }.count }
                print(
                    held > 0
                        ? "Nothing to clean. \(held) item(s) need --include-review (and --rule for caution rules)."
                        : "Nothing to clean.")
            }
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
