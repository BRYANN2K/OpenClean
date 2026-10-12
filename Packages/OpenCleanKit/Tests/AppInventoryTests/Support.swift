import Foundation
import TestSupport

@testable import AppInventory

enum FakeApps {
    /// Writes `<relative>/Contents/Info.plist` and a small executable, returning the bundle path.
    @discardableResult
    static func make(
        _ dir: TempDirectory, _ relative: String, id: String?, bundleName: String? = nil, version: String? = "1.0",
        bytes: Int = 4_096
    ) throws -> String {
        let bundle = try dir.directory(relative)
        var info: [String: Any] = ["CFBundlePackageType": "APPL"]
        if let id { info["CFBundleIdentifier"] = id }
        if let bundleName { info["CFBundleName"] = bundleName }
        if let version { info["CFBundleShortVersionString"] = version }
        try dir.directory(relative + "/Contents/MacOS")
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: bundle + "/Contents/Info.plist"))
        try dir.file(relative + "/Contents/MacOS/app", bytes: bytes)
        return bundle
    }
}

struct FixedLastUsed: LastUsedProvider {
    let dates: [String: Date]

    func lastUsedDates(for paths: [String]) -> [String: Date] {
        dates.filter { paths.contains($0.key) }
    }
}

func setPermissions(_ path: String, _ mode: Int) throws {
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
}
