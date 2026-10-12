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
}
