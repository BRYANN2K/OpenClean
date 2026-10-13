import Foundation

// This target's strings live in Resources/Localizable.xcstrings, which SwiftPM compiles into the
// `OpenClean_OpenCleanAppModel.bundle` resource bundle. `make app` copies that bundle into
// OpenClean.app/Contents/Resources.
//
// `Bundle.module` isn't used: depending on the SwiftPM version, its generated accessor looks only next to
// the executable or at an absolute build path and calls `fatalError` when the bundle isn't there. This
// lookup never crashes; without the bundle, strings fall back to their English source text.

private final class BundleFinder {}

extension Bundle {
    /// The resource bundle with OpenCleanAppModel's translations, or `.main` when it can't be found.
    public static let appModel: Bundle = {
        let name = "OpenClean_OpenCleanAppModel.bundle"
        let candidates: [URL?] = [
            // OpenClean.app/Contents/Resources.
            Bundle.main.resourceURL,
            // Next to the executable: `swift run`, `.build/debug`.
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle.main.bundleURL,
            // Tests: next to the .xctest bundle.
            Bundle(for: BundleFinder.self).bundleURL.deletingLastPathComponent(),
        ]
        for candidate in candidates {
            if let url = candidate?.appendingPathComponent(name), let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return .main
    }()
}
