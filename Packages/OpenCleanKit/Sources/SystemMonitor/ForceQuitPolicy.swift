import Foundation

/// Decides which processes OpenClean may offer to quit. Fails closed: anything that looks like part of
/// macOS, belongs to another user, or is OpenClean itself is never offered Quit or Force Quit.
public struct ForceQuitPolicy: Sendable {
    /// Process names that keep the session alive or that macOS restarts immediately.
    public static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "Dock", "Finder", "SystemUIServer",
        "ControlCenter", "NotificationCenter", "coreaudiod", "mds", "mds_stores", "mdworker", "cfprefsd",
        "opendirectoryd", "securityd", "trustd", "distnoted", "UserEventAgent", "logd", "syslogd",
        "configd", "powerd", "fseventsd", "hidd", "coreservicesd", "launchservicesd", "runningboardd",
        "OpenClean", "OpenCleanApp", "openclean",
    ]

    /// Executables inside these folders ship with macOS.
    /// Apps in an `Applications` folder (including /System/Applications: Music, Mail, Safari…) are exempt.
    public static let protectedRoots = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]

    public let ownPID: Int32
    public let currentUID: UInt32

    public init(ownPID: Int32 = ProcessInfo.processInfo.processIdentifier, currentUID: UInt32 = getuid()) {
        self.ownPID = ownPID
        self.currentUID = currentUID
    }

    public func isProtected(_ process: ProcessUsage) -> Bool {
        if process.pid <= 1 || process.pid == ownPID { return true }
        if process.uid != currentUID { return true }
        if Self.protectedNames.contains(process.name) { return true }
        guard let path = process.path else { return true }
        let bundle = ProcessUsageCalculator.outermostAppBundle(path)
        if let bundle, Self.protectedNames.contains(ProcessUsageCalculator.appName(fromBundlePath: bundle)) {
            return true
        }
        if let bundle, Self.isInApplicationsFolder(bundle) { return false }
        let bytes = Array(path.utf8)
        for root in Self.protectedRoots {
            let prefix = Array(root.utf8)
            if bytes.count >= prefix.count, bytes[..<prefix.count].elementsEqual(prefix) { return true }
        }
        return false
    }

    /// The bundle sits directly in an `Applications` or `Applications/Utilities` folder.
    static func isInApplicationsFolder(_ bundle: String) -> Bool {
        let parent = Array((bundle as NSString).deletingLastPathComponent.utf8)
        for suffix in ["/Applications", "/Applications/Utilities"] {
            let tail = Array(suffix.utf8)
            if parent.count >= tail.count, parent[(parent.count - tail.count)...].elementsEqual(tail) { return true }
        }
        return false
    }
}
