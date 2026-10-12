import Foundation

/// A byte count that decodes from an integer or a decimal string such as "10MB" or "1.5 GB".
public struct ByteSize: Decodable, Sendable, Equatable, Comparable, CustomStringConvertible {
    public let bytes: Int64

    public init(bytes: Int64) {
        self.bytes = bytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int64.self) {
            guard number >= 0 else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "size must be >= 0")
            }
            bytes = number
            return
        }
        let text = try container.decode(String.self)
        guard let parsed = ByteSize.parse(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid size '\(text)'")
        }
        bytes = parsed.bytes
    }

    /// Parses decimal (1000-based, matching Finder) sizes: B, KB, MB, GB, TB. Case-insensitive.
    public static func parse(_ text: String) -> ByteSize? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard !trimmed.isEmpty else { return nil }
        let units: [(suffix: String, factor: Double)] = [
            ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1),
        ]
        for unit in units where trimmed.hasSuffix(unit.suffix) {
            let number = trimmed.dropLast(unit.suffix.count).trimmingCharacters(in: .whitespaces)
            guard let value = Double(number), value.isFinite, value >= 0 else { return nil }
            let product = value * unit.factor
            // Double(Int64.max) rounds up to 2^63, which Int64 cannot hold, so the bound is exclusive.
            guard product.isFinite, product < Double(Int64.max) else { return nil }
            return ByteSize(bytes: Int64(product))
        }
        guard let value = Int64(trimmed), value >= 0 else { return nil }
        return ByteSize(bytes: value)
    }

    public static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func < (lhs: ByteSize, rhs: ByteSize) -> Bool { lhs.bytes < rhs.bytes }

    public var description: String { ByteSize.format(bytes) }
}
