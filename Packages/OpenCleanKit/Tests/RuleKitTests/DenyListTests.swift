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
}
