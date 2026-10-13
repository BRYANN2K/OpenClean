import ArgumentParser
import Foundation
import RuleKit
import SpaceKit

struct SpaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "space", abstract: "Find large files and duplicates. Nothing is removed.",
        subcommands: [SpaceLargeCommand.self, SpaceDuplicatesCommand.self])
}

struct SpaceLargeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "large", abstract: "List large files in your home folder, largest first. Nothing is removed.")

    @Option(name: .customLong("min-size"), help: "Only files at least this big, e.g. 500MB or 1GB.")
    var minSize: ByteSize = ByteSize(bytes: LargeFileFilter().minimumSize)

    @Option(name: .customLong("older-than"), help: "Only files not opened for at least this many days.")
    var olderThan: Int?

    @Option(name: .customLong("root"), help: "Folder to search instead of your home folder (repeatable).")
    var roots: [String] = []

    @Flag(name: .customLong("include-documents"), help: "Also search Documents and Desktop.")
    var includeDocuments = false

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func validate() throws {
        if let olderThan, olderThan < 0 { throw ValidationError("--older-than must be 0 or more days") }
    }

    func run() async throws {
        let coordinator = CLI.coordinator()
        _ = CLI.bootstrap(coordinator)
        let filter = LargeFileFilter(minimumSize: minSize.bytes, notOpenedForDays: olderThan)
        let result = await coordinator.findLargeFiles(
            roots: roots.isEmpty ? nil : roots,
            options: LargeFileOptions(minimumSize: minSize.bytes, includeUserContent: includeDocuments))
        let files = filter.apply(result.files)
        print(
            json
                ? try JSONReport.largeFiles(result, files: files, filter: filter)
                : TextReport.largeFiles(result, files: files, filter: filter))
    }
}

struct SpaceDuplicatesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "duplicates",
        abstract: "Find identical files (same SHA-256) in Downloads, Desktop, Documents, Pictures, Movies and Music.")

    @Option(name: .customLong("min-size"), help: "Ignore files smaller than this, e.g. 10MB.")
    var minSize: ByteSize = ByteSize(bytes: DuplicateOptions().minimumSize)

    @Option(name: .customLong("root"), help: "Folder to search instead of the default folders (repeatable).")
    var roots: [String] = []

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() async throws {
        let coordinator = CLI.coordinator()
        _ = CLI.bootstrap(coordinator)
        let result = await coordinator.findDuplicates(
            roots: roots.isEmpty ? nil : roots, options: DuplicateOptions(minimumSize: minSize.bytes))
        print(json ? try JSONReport.duplicates(result) : TextReport.duplicates(result))
    }
}

extension ByteSize: ExpressibleByArgument {
    public init?(argument: String) {
        guard let parsed = ByteSize.parse(argument) else { return nil }
        self = parsed
    }

    public var defaultValueDescription: String { description }
}
