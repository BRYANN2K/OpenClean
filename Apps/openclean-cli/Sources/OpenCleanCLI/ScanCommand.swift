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
