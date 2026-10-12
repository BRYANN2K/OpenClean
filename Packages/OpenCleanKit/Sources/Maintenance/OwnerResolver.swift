import Foundation

/// An installed application, as far as owner resolution needs to know.
public struct InstalledApp: Sendable, Equatable {
    public var name: String
    public var bundleID: String
    public var path: String

    public init(name: String, bundleID: String, path: String) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
    }

    /// Top-level `.app` bundles in the given folders (no recursion), with their bundle identifiers.
    public static func scan(directories: [String]) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        for directory in directories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for name in names.sorted() where name.hasSuffix(".app") {
                let path = (directory as NSString).appendingPathComponent(name)
                guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier else { continue }
                apps.append(InstalledApp(name: displayName(bundle, fileName: name), bundleID: id, path: path))
            }
        }
        return apps
    }

    static func displayName(_ bundle: Bundle, fileName: String) -> String {
        let info = bundle.infoDictionary ?? [:]
        if let name = info["CFBundleDisplayName"] as? String, !name.isEmpty { return name }
        if let name = info["CFBundleName"] as? String, !name.isEmpty { return name }
        return String(fileName.dropLast(4))
    }
}

/// Works out which app a launch item belongs to.
public struct OwnerResolver: Sendable {
    let apps: [InstalledApp]
    /// Reads a bundle's identifier and name; injectable so tests don't need real bundles.
    let bundleInfo: @Sendable (String) -> (name: String, bundleID: String?)?

    public init(
        apps: [InstalledApp],
        bundleInfo: @escaping @Sendable (String) -> (name: String, bundleID: String?)? = OwnerResolver.readBundle
    ) {
        self.apps = apps
        self.bundleInfo = bundleInfo
    }

    public static let readBundle: @Sendable (String) -> (name: String, bundleID: String?)? = { path in
        guard let bundle = Bundle(path: path) else { return nil }
        return (
            InstalledApp.displayName(bundle, fileName: (path as NSString).lastPathComponent), bundle.bundleIdentifier
        )
    }

    public func owner(of definition: LaunchItemDefinition) -> LaunchItemOwner? {
        // 1. The program lives inside an app bundle.
        if let program = definition.program, let bundle = Self.outermostAppBundle(program) {
            if let info = bundleInfo(bundle) {
                return LaunchItemOwner(
                    appName: info.name, bundleID: info.bundleID, bundlePath: bundle, confidence: .exact)
            }
            let name = String((bundle as NSString).lastPathComponent.dropLast(4))
            return LaunchItemOwner(appName: name, bundleID: nil, bundlePath: bundle, confidence: .exact)
        }
        let label = definition.label.lowercased()
        // 2. The label is an installed app's bundle id, or starts with it ("com.vendor.app.helper").
        let exact = apps.filter { app in
            let id = app.bundleID.lowercased()
            return label == id || label.hasPrefix(id + ".")
        }
        if let best = exact.max(by: { $0.bundleID.count < $1.bundleID.count }) {
            return LaunchItemOwner(
                appName: best.name, bundleID: best.bundleID, bundlePath: best.path, confidence: .exact)
        }
        // 3. Same vendor (first two reverse-DNS components), only when exactly one app matches.
        if let vendor = Self.vendorPrefix(label) {
            let matches = apps.filter { Self.vendorPrefix($0.bundleID.lowercased()) == vendor }
            if matches.count == 1, let app = matches.first {
                return LaunchItemOwner(
                    appName: app.name, bundleID: app.bundleID, bundlePath: app.path, confidence: .likely)
            }
        }
        return nil
    }

    /// "com.google.keystone.agent" → "com.google"; nil for one-component labels and generic prefixes.
    static func vendorPrefix(_ identifier: String) -> String? {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let prefix = "\(parts[0]).\(parts[1])"
        return ["com.apple", "com.github", "io.github"].contains(prefix) ? nil : prefix
    }

    /// Byte-level search for the first `<name>.app/` component.
    static func outermostAppBundle(_ path: String) -> String? {
        let bytes = Array(path.utf8)
        let marker = Array(".app/".utf8)
        guard bytes.first == 0x2F, bytes.count > marker.count else { return nil }
        var index = 1
        while index + marker.count <= bytes.count {
            if bytes[index..<(index + marker.count)].elementsEqual(marker), bytes[index - 1] != 0x2F {
                return String(decoding: bytes[..<(index + 4)], as: UTF8.self)
            }
            index += 1
        }
        return nil
    }
}
