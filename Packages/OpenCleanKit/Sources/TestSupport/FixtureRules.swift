import Foundation

/// A small rule pack used by coordinator, CLI and app-model tests.
public enum FixtureRules {
    public static let yaml = """
        pack: fixture
        version: 1
        rules:
          - id: fixture.caches
            name: Fixture caches
            category: user
            explain: Test caches that apps rebuild.
            paths: ["~/Library/Caches/*"]
            safety: regenerable
          - id: fixture.downloads
            name: Old downloads
            category: user
            explain: Test downloads you may not need.
            paths: ["~/Downloads/*"]
            safety: review
          - id: fixture.risky
            name: Risky files
            category: user
            explain: Test files that need care.
            paths: ["~/Risky/*"]
            safety: caution
        """

    /// Writes `fixture.yaml` into `<dir>/rules` and returns that directory's path.
    public static func writeDirectory(in dir: TempDirectory) throws -> String {
        let rules = try dir.directory("rules")
        try yaml.write(toFile: rules + "/fixture.yaml", atomically: true, encoding: .utf8)
        return rules
    }
}
