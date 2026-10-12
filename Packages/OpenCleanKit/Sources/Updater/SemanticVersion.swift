import Foundation

/// A release version `X.Y.Z`, optionally written with a leading `v` (`v0.3.0`) and an optional
/// pre-release suffix after a hyphen (`1.0.0-beta.2`).
///
/// Ordering compares major, minor and patch numerically. A pre-release sorts below the plain release
/// with the same numbers (`1.0.0-beta < 1.0.0`); two pre-releases of the same numbers compare their
/// suffixes as plain strings. The updater never offers a pre-release as "the latest version"
/// (`isPrerelease` releases are ignored), so the suffix ordering only matters for completeness.
/// Build metadata (`+…`) is not accepted.
public struct SemanticVersion: Sendable, Hashable, Comparable, CustomStringConvertible, Codable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// The text after `-`, or nil for a normal release.
    public let prerelease: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Parses `X.Y.Z`, `vX.Y.Z` or `X.Y.Z-suffix`. Returns nil for anything else (two-part versions,
    /// leading zeros are allowed, signs and whitespace are not).
    public init?(_ text: String) {
        var body = Substring(text)
        if body.first == "v" || body.first == "V" { body = body.dropFirst() }
        var prerelease: String?
        if let dash = body.firstIndex(of: "-") {
            let suffix = body[body.index(after: dash)...]
            guard !suffix.isEmpty,
                suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
            else { return nil }
            prerelease = String(suffix)
            body = body[..<dash]
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                let value = Int(part)
            else { return nil }
            numbers.append(value)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: prerelease)
    }

    public var isPrerelease: Bool { prerelease != nil }

    /// `X.Y.Z` without the pre-release suffix: digits and dots only, safe as a folder name.
    public var core: String { "\(major).\(minor).\(patch)" }

    public var description: String { prerelease.map { "\(core)-\($0)" } ?? core }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _): return false
        case (_, nil): return true
        case (let left?, let right?): return left < right
        }
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = SemanticVersion(text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "not a version: \(text)"))
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
