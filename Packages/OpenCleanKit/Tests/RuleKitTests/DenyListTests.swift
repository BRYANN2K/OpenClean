import Testing
@testable import RuleKit

struct DenyListTests {
    let deny = DenyList(home: "/Users/tester")

    @Test(arguments: [
        "/", "/System/Library/Caches", "/usr/bin/true", "/bin/ls", "/sbin",
        "/Users/tester", "/Users/tester/Documents/report.pdf", "/Users/tester/Desktop/x",
        "/Users/tester/Library/Keychains/login.keychain-db", "/Library/Keychains/System.keychain",
        "/Users/tester/Library/Mail/V10", "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/a",
        "/Applications/Safari.app", "/Applications/Xcode.app/Contents/Developer",
        "/Users/tester/Applications/Foo.app/Contents",
        "/Users/tester/Pictures/Photos Library.photoslibrary/database",
        // ancestors of protected locations
        "/Users", "/Users/tester/Library", "/Library", "/Applications", "/Users/tester/Pictures", "/usr",
    ])
    func deniesProtectedPaths(path: String) {
        #expect(deny.isDenied(path), "expected \(path) to be denied")
    }

    @Test(arguments: [
        "/usr/local/Cellar/x", "/Library/Caches/com.example", "/private/var/log/system.log.0.gz",
        "/Users/tester/Library/Caches/com.example", "/Users/tester/.npm/_cacache",
        "/Users/tester/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/a.pdf",
        "/Applications/Utilities.txt", "/Users/tester/Pictures/holiday.jpg",
    ])
    func allowsOrdinaryPaths(path: String) {
        #expect(!deny.isDenied(path), "expected \(path) to be allowed: \(deny.denialReason(for: path) ?? "")")
    }

    @Test(arguments: [
        "/Users/tester/Library/Caches/../../Documents/x", "/Users/tester/./Documents/x", "Documents/x", "",
        "/users/TESTER/documents/x", "/applications/safari.app",
        "/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
        "/Users/tester/Library/Caches/../\u{0301}Documents/x", "/Users/tester/./\u{0301}x",
    ])
    func deniesNonCanonicalCaseAndNestedBundles(path: String) {
        #expect(deny.isDenied(path), "expected \(path) to be denied")
    }

    @Test func caseVariantStillAllowedWhenOrdinary() {
        #expect(!deny.isDenied("/Library/Caches/com.Example"))
        #expect(!deny.isDenied("/Applications/Utilities"))
        #expect(!deny.isDenied("/Library/Caches/cafe\u{0301}"))
    }

    @Test func reasonsKeepConfiguredRootText() {
        #expect(deny.denialReason(for: "/Users/tester/Documents/x") == "inside protected location /Users/tester/Documents")
        #expect(deny.denialReason(for: "/users/tester/documents/x") == "inside protected location /Users/tester/Documents")
    }

    @Test(arguments: [
        "/Users/tester/Documents/\u{0301}x", "/Users/tester/Desktop/\u{0301}", "/System/\u{0301}x",
        "/usr/\u{0301}bin", "/Users/tester/Library/Keychains/\u{0301}login.keychain-db",
        "/Applications/\u{0301}Safari.app", "/Applications/Safari.app/\u{0301}x",
        "/Users/tester/Pictures/\u{0301}x.photoslibrary",
    ])
    func deniesPathsWithCombiningMarkAfterSlash(path: String) {
        #expect(deny.isDenied(path), "expected \(path) to be denied")
    }

    @Test(arguments: ["/Library/Caches/cafe\u{0301}", "/Users/tester/Library/Caches/\u{0301}x"])
    func allowsCombiningMarksInOrdinaryPaths(path: String) {
        #expect(!deny.isDenied(path), "expected \(path) to be allowed: \(deny.denialReason(for: path) ?? "")")
    }

    @Test(arguments: [
        "/Applications/Foo\u{0600}.app", "/Applications/Foo\u{0600}.app/Contents/x",
        "/Users/tester/Applications/a/Foo\u{0600}.app/x", "/Users/tester/Pictures/x\u{0600}.photoslibrary",
        "/Users/tester/Pictures/x\u{0600}.photoslibrary/database",
        "/APPLICATIONS/\u{0301}Safari.app", "/system/\u{0301}x", "/usr/loca\u{0301}l/x",
    ])
    func deniesPrependCharsCaseAndEquivalents(path: String) {
        #expect(deny.isDenied(path), "expected \(path) to be denied")
    }

    @Test func allowsUsrLocalWithCombiningMark() {
        #expect(!deny.isDenied("/usr/local/\u{0301}x"))
    }

    @Test func treatsCanonicallyEquivalentHomesAsEqual() {
        let nfcHome = DenyList(home: "/Users/Jos\u{e9}")
        let nfdHome = DenyList(home: "/Users/Jose\u{301}")
        #expect(nfcHome.isDenied("/Users/Jose\u{301}/Documents/x"))
        #expect(nfdHome.isDenied("/Users/Jos\u{e9}/Documents/x"))
    }
}
