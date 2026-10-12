import Foundation

public enum FullDiskAccessStatus: String, Sendable {
    case granted, denied, unknown
}

/// Detects Full Disk Access by listing a TCC-protected folder. Never assumes.
public struct FullDiskAccessChecker: Sendable {
    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    let probePaths: [String]

    public init(home: String, probePaths: [String]? = nil) {
        self.probePaths = probePaths ?? [
            home + "/Library/Safari",
            home + "/Library/Containers/com.apple.stocks",
        ]
    }

    public func status() -> FullDiskAccessStatus {
        for path in probePaths where FileManager.default.fileExists(atPath: path) {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: path)
                return .granted
            } catch {
                return .denied
            }
        }
        return .unknown
    }
}
