import ArgumentParser
import Foundation
import OpenCleanKit
import Quarantine
import RuleKit

enum CLI {
    static func coordinator() -> OpenCleanCoordinator { OpenCleanCoordinator() }

    /// Loads settings and purges expired quarantine sessions; runs at every invocation.
    static func bootstrap(_ coordinator: OpenCleanCoordinator) -> Settings {
        let settings = coordinator.settingsStore.load()
        coordinator.purgeExpired(settings: settings)
        return settings
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func printProblems(_ problems: [String]) {
        problems.forEach(printError)
    }
}

extension RuleCategory: ExpressibleByArgument {}
extension ConflictPolicy: ExpressibleByArgument {}
