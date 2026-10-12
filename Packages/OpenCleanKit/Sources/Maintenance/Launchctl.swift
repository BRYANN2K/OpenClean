import Foundation

/// Builds `launchctl` argument vectors. Arguments go straight to `execve` (never a shell), and labels
/// are validated so a hostile label can't address a different service or domain.
public enum LaunchctlCommand {
    public static let executable = "/bin/launchctl"

    /// A label must be non-empty, at most 255 bytes, and free of `/`, NUL and control characters.
    public static func isValidLabel(_ label: String) -> Bool {
        let bytes = Array(label.utf8)
        guard !bytes.isEmpty, bytes.count <= 255 else { return false }
        return !bytes.contains { $0 == 0x2F || $0 < 0x20 || $0 == 0x7F }
    }

    public static func guiDomain(uid: UInt32) -> String { "gui/\(uid)" }

    static func service(uid: UInt32, label: String) throws -> String {
        guard isValidLabel(label) else { throw LoginItemsError.invalidLabel(label) }
        return "\(guiDomain(uid: uid))/\(label)"
    }

    public static func list() -> [String] { ["list"] }
    public static func printDisabled(uid: UInt32) -> [String] { ["print-disabled", guiDomain(uid: uid)] }

    public static func printSystem(label: String) throws -> [String] {
        guard isValidLabel(label) else { throw LoginItemsError.invalidLabel(label) }
        return ["print", "system/\(label)"]
    }

    public static func bootout(uid: UInt32, label: String) throws -> [String] {
        ["bootout", try service(uid: uid, label: label)]
    }

    public static func disable(uid: UInt32, label: String) throws -> [String] {
        ["disable", try service(uid: uid, label: label)]
    }

    public static func enable(uid: UInt32, label: String) throws -> [String] {
        ["enable", try service(uid: uid, label: label)]
    }

    public static func bootstrap(uid: UInt32, plistPath: String) throws -> [String] {
        guard plistPath.utf8.first == 0x2F, !plistPath.utf8.contains(0) else {
            throw LoginItemsError.notActionable(plistPath)
        }
        return ["bootstrap", guiDomain(uid: uid), plistPath]
    }
}

/// Defensive parsers for `launchctl` text output, which is not a stable interface.
public enum LaunchctlParser {
    public struct ListEntry: Sendable, Equatable {
        public var pid: Int32?
        public var lastExitStatus: Int32?
    }

    /// `launchctl list`: a "PID Status Label" header, then tab-separated rows; PID is "-" when not running.
    /// Lines that don't fit are ignored.
    public static func parseList(_ output: String) -> [String: ListEntry] {
        var entries: [String: ListEntry] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let pidField = fields[0].trimmingCharacters(in: .whitespaces)
            let statusField = fields[1].trimmingCharacters(in: .whitespaces)
            let label = String(fields[2])
            if pidField == "PID" && label == "Label" { continue }
            guard !label.isEmpty, pidField == "-" || Int32(pidField) != nil else { continue }
            entries[label] = ListEntry(pid: Int32(pidField), lastExitStatus: Int32(statusField))
        }
        return entries
    }

    /// `launchctl print-disabled <domain>`: lines like `"label" => disabled` (older: `=> true`).
    /// Returns label → isDisabled.
    public static func parseDisabled(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.first == "\"", let arrow = line.range(of: "\" => ") else { continue }
            let label = String(line[line.index(after: line.startIndex)..<arrow.lowerBound])
            let value = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            switch value {
            case "disabled", "true": result[label] = true
            case "enabled", "false": result[label] = false
            default: continue
            }
        }
        return result
    }
}
