import Testing

@testable import RuleKit

struct ByteSizeTests {
    @Test func parsesDecimalUnits() {
        #expect(ByteSize.parse("10MB") == ByteSize(bytes: 10_000_000))
        #expect(ByteSize.parse("1.5 GB") == ByteSize(bytes: 1_500_000_000))
        #expect(ByteSize.parse("500kb") == ByteSize(bytes: 500_000))
        #expect(ByteSize.parse("512") == ByteSize(bytes: 512))
        #expect(ByteSize.parse("2TB") == ByteSize(bytes: 2_000_000_000_000))
    }

    @Test func rejectsGarbageAndNegatives() {
        #expect(ByteSize.parse("ten MB") == nil)
        #expect(ByteSize.parse("-5MB") == nil)
        #expect(ByteSize.parse("") == nil)
    }

    @Test func rejectsValuesThatDoNotFitInt64() {
        #expect(ByteSize.parse("1e30TB") == nil)
        #expect(ByteSize.parse("inf") == nil)
        #expect(ByteSize.parse("nan") == nil)
        #expect(ByteSize.parse("infTB") == nil)
        #expect(ByteSize.parse("nanMB") == nil)
        #expect(ByteSize.parse("9300000000000000000B") == nil)
        // Exactly 2^63 written with a unit: Double(Int64.max) rounds to this value, so `<=` would still trap.
        #expect(ByteSize.parse("9223372036854775808B") == nil)
    }
}
