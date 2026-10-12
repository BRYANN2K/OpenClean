import Foundation

/// Finds the bundled rule packs:
/// 1. `$OPENCLEAN_RULES_DIR`
/// 2. `OpenClean.app/Contents/Resources/Rules`
/// 3. `<bin>/../share/openclean/rules` (installed CLI)
/// 4. `<repo>/Rules` (development checkout)
public enum RulesLocator {
    public static func bundledDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment, mainBundle: Bundle = .main
    ) -> URL? {
        var candidates: [URL] = []
        if let override = environment["OPENCLEAN_RULES_DIR"] {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let resources = mainBundle.resourceURL {
            candidates.append(resources.appendingPathComponent("Rules", isDirectory: true))
        }
        if let executable = mainBundle.executableURL?.resolvingSymlinksInPath() {
            candidates.append(
                executable.deletingLastPathComponent()
                    .appendingPathComponent("../share/openclean/rules", isDirectory: true).standardizedFileURL)
        }
        // <repo>/Packages/OpenCleanKit/Sources/OpenCleanKit/RulesLocator.swift
        let sourceFile = URL(fileURLWithPath: #filePath)
        candidates.append(
            sourceFile.deletingLastPathComponent()
                .appendingPathComponent("../../../../Rules", isDirectory: true).standardizedFileURL)

        return candidates.first { directory in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.contains { $0.hasSuffix(".yaml") || $0.hasSuffix(".yml") }
        }
    }
}
