import Foundation
import RuleKit
import TestSupport
import Testing

/// <repo>/Apps/openclean-cli/Tests/OpenCleanCLITests/Support.swift
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

enum Golden {
    /// Compares against `Golden/<name>`. Run with OPENCLEAN_RECORD_GOLDEN=1 to (re)write the file.
    static func check(_ actual: String, named name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Golden").appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["OPENCLEAN_RECORD_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (actual + "\n").write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        #expect(actual + "\n" == expected, sourceLocation: sourceLocation)
    }
}

struct CLIRun {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum CLIBinary {
    static var url: URL { repoRoot.appendingPathComponent(".build/debug/openclean") }

    /// Runs the built `openclean` binary with stdin closed (never a TTY).
    static func run(_ arguments: [String], environment: [String: String]) throws -> CLIRun {
        guard let home = environment["OPENCLEAN_HOME"], let realHome = realPath(home),
            let realTemp = realPath(NSTemporaryDirectory()), pathIsWithin(realHome, realTemp)
        else {
            throw CocoaError(
                .fileReadInvalidFileName,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "CLIBinary.run refuses to run: OPENCLEAN_HOME must be set to a directory inside NSTemporaryDirectory()"
                ])
        }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path + " (run `swift build` first)"])
        }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            .merging(["HOME": home, "CFFIXED_USER_HOME": home]) { _, new in new }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CLIRun(
            status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self))
    }
}

enum CLIFixtures {
    /// Runs `body` with a fixture home that stays alive for the whole call.
    static func withHome<T>(_ body: (TempDirectory, [String: String]) throws -> T) throws -> T {
        let home = try TempDirectory()
        let rules = try FixtureRules.writeDirectory(in: home)
        let environment = ["OPENCLEAN_HOME": home.path, "OPENCLEAN_RULES_DIR": rules]
        return try withExtendedLifetime(home) { try body(home, environment) }
    }

    static func json(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
