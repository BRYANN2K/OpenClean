import Foundation
import Security

public enum AccessAdvice: Sendable, Equatable {
    case ok
    case grant
    /// Access was granted to an earlier build; ad-hoc rebuilds change the signature TCC checks.
    case regrantAfterRebuild
}

public struct SignatureTracker: @unchecked Sendable {
    static let key = "fullDiskAccess.lastGrantedSignature"
    let defaults: UserDefaults
    let currentSignature: String?

    public init(defaults: UserDefaults, currentSignature: String?) {
        self.defaults = defaults
        self.currentSignature = currentSignature
    }

    public func advise(status: FullDiskAccessStatus) -> AccessAdvice {
        if status == .granted {
            if let currentSignature { defaults.set(currentSignature, forKey: Self.key) }
            return .ok
        }
        if let last = defaults.string(forKey: Self.key), let currentSignature, last != currentSignature {
            return .regrantAfterRebuild
        }
        return .grant
    }

    /// Hex code-directory hash of the running executable, or nil if unsigned.
    public static func currentCDHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
            let dictionary = info as? [String: Any],
            let unique = dictionary[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}
