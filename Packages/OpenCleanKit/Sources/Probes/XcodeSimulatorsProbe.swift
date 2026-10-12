import Foundation
import ProcessKit
import ScanEngine

/// Simulator devices whose runtime is no longer installed (`isAvailable == false`).
public struct XcodeSimulatorsProbe: Probe {
    public static let id = "xcode.simulators"
    let runner: any CommandRunner

    public init(runner: any CommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    struct Listing: Decodable {
        let devices: [String: [Device]]
    }

    struct Device: Decodable {
        let udid: String
        let name: String
        let isAvailable: Bool?
    }

    public func scan(_ context: ScanContext) async throws -> [ProbeFinding] {
        let output: CommandOutput
        do {
            output = try runner.run("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"])
        } catch {
            return []
        }
        guard output.status == 0 else { return [] }
        let listing = try JSONDecoder().decode(Listing.self, from: output.stdout)
        let root = context.home + "/Library/Developer/CoreSimulator/Devices/"
        return listing.devices.values.flatMap { $0 }
            .filter { $0.isAvailable == false }
            .sorted { $0.udid < $1.udid }
            .map { ProbeFinding(path: root + $0.udid, hint: "Unavailable simulator: \($0.name)") }
    }
}
