import Foundation
import Security

/// Who signed OpenClean, for checking that an update comes from the same publisher.
///
/// `SHA256SUMS.txt` ships in the same GitHub release as the disk image, so it only proves the download
/// is intact. When the running app is signed with a Developer ID (it has a Team ID), a staged update must
/// be signed by that same team, which authenticates the publisher. Ad-hoc builds (development, forks,
/// releases built without the signing secrets) have no Team ID, so there is nothing to compare against
/// and only the plain signature check applies.
public enum PublisherCheck {
    /// The Team ID the running executable is signed with, or nil for ad-hoc / unsigned code.
    public static func runningTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
            let dictionary = info as? [String: Any],
            let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty
        else { return nil }
        return team
    }

    /// Apple Team IDs are ten upper-case letters or digits. Anything else is refused rather than pasted
    /// into a code requirement.
    public static func isValidTeamIdentifier(_ team: String) -> Bool {
        team.utf8.count == 10 && team.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }
    }

    /// A Developer ID Application signature from `team` for the bundle `identifier`: Apple-anchored, a
    /// Developer ID intermediate (1.2.840.113635.100.6.2.6) and leaf (1.2.840.113635.100.6.1.13), and the
    /// leaf's organisational unit equal to the Team ID. The same shape as the designated requirement
    /// `codesign` generates for Developer ID apps.
    public static func requirement(teamIdentifier team: String, bundleIdentifier identifier: String) -> String {
        "identifier \"\(identifier)\" and anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(team)\""
    }
}
