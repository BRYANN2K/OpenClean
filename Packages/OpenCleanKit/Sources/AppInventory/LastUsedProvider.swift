import Foundation
import ProcessKit

/// When each app was last opened, where Spotlight knows it. Missing entries just mean "unknown".
public protocol LastUsedProvider: Sendable {
    func lastUsedDates(for paths: [String]) -> [String: Date]
}

/// One batched `mdls -raw` call. Any failure (timeout, Spotlight off, odd output) returns no dates.
public struct MdlsLastUsedProvider: LastUsedProvider {
    let runner: any CommandRunner

    public init(runner: any CommandRunner = ProcessCommandRunner(timeout: 10)) {
        self.runner = runner
    }

    public func lastUsedDates(for paths: [String]) -> [String: Date] {
        guard !paths.isEmpty,
            let output = try? runner.run("/usr/bin/mdls", ["-raw", "-name", "kMDItemLastUsedDate"] + paths),
            output.status == 0
        else { return [:] }
        return Self.parse(output.stdout, paths: paths)
    }

    /// Values are NUL-separated, in argument order; "(null)" means unknown. A count mismatch means the
    /// output can't be attributed reliably, so nothing is returned.
    static func parse(_ data: Data, paths: [String]) -> [String: Date] {
        var fields = data.split(separator: 0x00, omittingEmptySubsequences: false)
        if fields.count == paths.count + 1, fields.last?.allSatisfy({ $0 == 0x0A }) == true { fields.removeLast() }
        guard fields.count == paths.count else { return [:] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var dates: [String: Date] = [:]
        for (path, field) in zip(paths, fields) {
            let text = String(decoding: field, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let date = formatter.date(from: text) { dates[path] = date }
        }
        return dates
    }
}
