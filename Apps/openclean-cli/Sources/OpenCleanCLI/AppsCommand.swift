import AppInventory
import ArgumentParser
import Darwin
import Foundation
import OpenCleanKit
import Quarantine
import RuleKit

/// An installed app with the leftovers OpenClean found for it.
public struct AppListing: Sendable {
    public let app: InstalledApp
    public let leftovers: [Leftover]

    public init(app: InstalledApp, leftovers: [Leftover]) {
        self.app = app
        self.leftovers = leftovers
    }
}

/// What `apps uninstall` would move: the app, then the chosen user-scope leftovers.
public struct UninstallPlan: Sendable {
    public let listing: AppListing
    public let chosen: [Leftover]

    /// Bundle-id leftovers are chosen by default (as in the app); name matches only with `includeNameMatches`.
    /// Report-only leftovers (in /Library) are never chosen.
    public init(listing: AppListing, includeNameMatches: Bool) {
        self.listing = listing
        chosen = listing.leftovers.filter {
            !$0.isReportOnly && ($0.isSelectedByDefault || includeNameMatches)
        }
    }

    public var paths: [String] { [listing.app.path] + chosen.map(\.path) }
    public var totalBytes: Int64 { chosen.reduce(listing.app.size) { $0 + $1.size } }
    /// Found but left in place: unticked name matches and report-only leftovers.
    public var staying: [Leftover] {
        let chosenPaths = Set(chosen.map(\.path))
        return listing.leftovers.filter { !chosenPaths.contains($0.path) }
    }
}

struct AppsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps", abstract: "List installed apps and uninstall them to quarantine.",
        subcommands: [AppsListCommand.self, AppsUninstallCommand.self])

    /// Every installed app with its leftovers, through the coordinator (as the app's Uninstaller does).
    static func listings(_ coordinator: OpenCleanCoordinator) async -> [AppListing] {
        let apps = await coordinator.installedApps()
        let bundleIDs = Set(apps.compactMap(\.bundleID))
        return apps.map { app in
            AppListing(
                app: app,
                leftovers: coordinator.leftovers(
                    for: app, otherBundleIDs: bundleIDs.subtracting([app.bundleID ?? ""])))
        }
    }
}

struct AppsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List installed apps with their leftovers and sizes. Nothing is removed.")

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() async throws {
        let coordinator = CLI.coordinator()
        _ = CLI.bootstrap(coordinator)
        let listings = await AppsCommand.listings(coordinator)
        print(json ? try JSONReport.apps(listings) : TextReport.apps(listings))
    }
}

struct AppsUninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Move an app and its leftovers to quarantine (restorable with `openclean restore`).")

    @Argument(help: "Bundle identifier of the app, e.g. com.example.app (see `openclean apps list`).")
    var bundleID: String

    @Option(help: "The app's path, when several installed apps share the bundle identifier.")
    var path: String?

    @Flag(
        name: .customLong("include-name-matches"),
        help: "Also move leftovers matched by the app's name (only bundle-id matches are moved by default).")
    var includeNameMatches = false

    @Flag(name: .customLong("dry-run"), help: "Show what would be moved, then stop.")
    var dryRun = false

    @Flag(name: [.customLong("yes"), .customShort("y")], help: "Do not ask for confirmation.")
    var yes = false

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    @Flag(
        name: .customLong("allow-admin"),
        help: "Allow an app that needs the administrator password when not running in a terminal.")
    var allowAdmin = false

    func run() async throws {
        if json && !dryRun && !yes {
            CLI.printError("--json requires --yes or --dry-run")
            throw ExitCode(1)
        }
        let coordinator = CLI.coordinator()
        let settings = CLI.bootstrap(coordinator)
        let listing = try await resolve(coordinator)
        let app = listing.app
        guard app.status.isRemovable else {
            CLI.printError("\(app.name) can't be uninstalled: \(app.status.explanation).")
            throw ExitCode(1)
        }
        let plan = UninstallPlan(listing: listing, includeNameMatches: includeNameMatches)
        let interactive = isatty(STDIN_FILENO) == 1
        let adminDropped = app.status.requiresAdministrator && !interactive && !allowAdmin

        if dryRun {
            print(
                json
                    ? try JSONReport.uninstallPlan(plan)
                    : TextReport.uninstallPlan(plan, retentionDays: settings.clampedRetentionDays))
            if adminDropped { CLI.printError(Self.adminMessage(app)) }
            return
        }
        if adminDropped {
            CLI.printError(Self.adminMessage(app))
            throw ExitCode(1)
        }
        if !json { print(TextReport.uninstallPlan(plan, retentionDays: settings.clampedRetentionDays)) }
        if !yes {
            guard interactive else {
                CLI.printError("Refusing to uninstall without confirmation. Re-run with --yes.")
                throw ExitCode(1)
            }
            print("Proceed? [y/N] ", terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print("Aborted.")
                throw ExitCode(1)
            }
        }

        switch try coordinator.uninstall(app, leftovers: plan.chosen) {
        case .refused(let refusal):
            CLI.printError("Not uninstalled: \(refusal.description). Nothing was moved.")
            throw ExitCode(1)
        case .finished(let report):
            print(json ? try JSONReport.cleanup(report) : TextReport.cleanup(report))
            if report.hadSkips { throw ExitCode(2) }
        }
    }

    static func adminMessage(_ app: InstalledApp) -> String {
        "\(app.name) needs the administrator password to uninstall; re-run in a terminal or pass --allow-admin."
    }

    /// The one app with `bundleID` (case-insensitive), or with `--path` among several.
    func resolve(_ coordinator: OpenCleanCoordinator) async throws -> AppListing {
        let wanted = bundleID.lowercased()
        var matches = await AppsCommand.listings(coordinator).filter { $0.app.bundleID?.lowercased() == wanted }
        if let path {
            let resolved = realPath(path) ?? path
            matches = matches.filter { $0.app.path == resolved }
        }
        guard let first = matches.first else {
            CLI.printError("No installed app with bundle identifier \(bundleID)\(path.map { " at \($0)" } ?? "").")
            throw ExitCode(1)
        }
        guard matches.count == 1 else {
            CLI.printError(
                "Several apps have bundle identifier \(bundleID); choose one with --path:\n"
                    + matches.map { "  " + $0.app.path }.joined(separator: "\n"))
            throw ExitCode(1)
        }
        return first
    }
}
