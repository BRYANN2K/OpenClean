import Foundation
import OpenCleanKit
import ScanEngine
import TestSupport
import Testing

@testable import OpenCleanAppModel

/// Records what would have been shown; never talks to UserNotifications.
final class FakeReminderNotifier: ScanReminderNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    private var posted: [(title: String, body: String)] = []
    let allow: Bool

    init(allow: Bool = true) { self.allow = allow }

    var authorizationRequests: Int { lock.withLock { requests } }
    var posts: [(title: String, body: String)] { lock.withLock { posted } }

    func requestAuthorization() async -> Bool {
        lock.withLock { requests += 1 }
        return allow
    }

    func isAuthorized() async -> Bool { allow }

    func post(title: String, body: String) async {
        lock.withLock { posted.append((title, body)) }
    }
}

/// A clock the reminder tests move by hand.
final class ReminderClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(days: Double) { lock.withLock { current += days * 86_400 } }
    func advance(seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// Counts background scans and returns a canned finding.
final class FakeBackgroundScan: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var bytes: Int64

    init(bytes: Int64) { self.bytes = bytes }

    var calls: Int { lock.withLock { count } }

    func run() -> ScanReminderFinding {
        lock.withLock {
            count += 1
            return ScanReminderFinding(date: .distantPast, bytes: bytes, itemCount: 3)
        }
    }
}

struct ScanReminderScheduleTests {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    let schedule = ScanReminderSchedule(calendar: utc)

    @Test func offNeverSchedules() {
        let now = Self.date("2026-03-01T10:00:00Z")
        #expect(schedule.nextScan(frequency: .off, enabledAt: now, lastScan: nil, now: now) == nil)
        #expect(!schedule.isDue(frequency: .off, enabledAt: .distantPast, lastScan: nil, now: now))
    }

    @Test func noAnchorNeverSchedules() {
        let now = Self.date("2026-03-01T10:00:00Z")
        #expect(schedule.nextScan(frequency: .weekly, enabledAt: nil, lastScan: nil, now: now) == nil)
    }

    @Test func weeklyIsSevenDaysAfterTheLaterAnchor() {
        let enabled = Self.date("2026-03-01T10:00:00Z")
        let scanned = Self.date("2026-03-05T08:00:00Z")
        let now = Self.date("2026-03-06T00:00:00Z")
        #expect(
            schedule.nextScan(frequency: .weekly, enabledAt: enabled, lastScan: nil, now: now)
                == Self.date("2026-03-08T10:00:00Z"))
        #expect(
            schedule.nextScan(frequency: .weekly, enabledAt: enabled, lastScan: scanned, now: now)
                == Self.date("2026-03-12T08:00:00Z"))
    }

    @Test func monthlyUsesCalendarMonths() {
        let enabled = Self.date("2026-01-31T09:00:00Z")
        #expect(
            schedule.nextScan(frequency: .monthly, enabledAt: enabled, lastScan: nil, now: enabled)
                == Self.date("2026-02-28T09:00:00Z"))
    }

    @Test func dueExactlyAtTheNextDate() {
        let enabled = Self.date("2026-03-01T10:00:00Z")
        let next = Self.date("2026-03-08T10:00:00Z")
        #expect(!schedule.isDue(frequency: .weekly, enabledAt: enabled, lastScan: nil, now: next - 1))
        #expect(schedule.isDue(frequency: .weekly, enabledAt: enabled, lastScan: nil, now: next))
    }

    @Test func anchorInTheFutureCountsAsNow() {
        // The clock was set back: a "last scan" in 2030 must not postpone the next one until 2030.
        let now = Self.date("2026-03-01T10:00:00Z")
        let future = Self.date("2030-01-01T00:00:00Z")
        #expect(
            schedule.nextScan(frequency: .weekly, enabledAt: nil, lastScan: future, now: now)
                == Self.date("2026-03-08T10:00:00Z"))
    }
}

@MainActor
struct ScanReminderModelTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    struct Harness {
        let defaults: UserDefaults
        let clock: ReminderClock
        let scan: FakeBackgroundScan
        let notifier: FakeReminderNotifier
    }

    func makeHarness(bytes: Int64 = 5_000_000_000, allow: Bool = true) -> Harness {
        let suite = "openclean.scanreminder.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return Harness(
            defaults: defaults, clock: ReminderClock(Self.start), scan: FakeBackgroundScan(bytes: bytes),
            notifier: FakeReminderNotifier(allow: allow))
    }

    func makeModel(_ h: Harness, isBusy: @escaping @MainActor () -> Bool = { false }) -> ScanReminderModel {
        let clock = h.clock
        let scan = h.scan
        return ScanReminderModel(
            settings: ScanReminderSettingsStore(defaults: h.defaults), scan: { scan.run() }, notifier: h.notifier,
            isBusy: isBusy, schedule: ScanReminderSchedule(calendar: ScanReminderScheduleTests.utc),
            notificationThreshold: 1_000_000_000, busyRetryDelay: 15 * 60, maxSleep: 3_600, now: { clock.now })
    }

    @Test func offByDefaultAndNeverScans() async {
        let h = makeHarness()
        let model = makeModel(h)
        model.start()
        defer { model.stop() }
        #expect(model.frequency == .off)
        #expect(!model.isScheduled)
        h.clock.advance(days: 400)
        #expect(await model.runIfDue() == false)
        #expect(h.scan.calls == 0)
        #expect(h.notifier.authorizationRequests == 0)
        #expect(h.notifier.posts.isEmpty)
        #expect(model.notice == nil)
    }

    @Test func turningOnAsksForPermissionAndWaitsOnePeriod() async {
        let h = makeHarness()
        let model = makeModel(h)
        model.start()
        defer { model.stop() }
        await model.setFrequency(.weekly)
        #expect(h.notifier.authorizationRequests == 1)
        #expect(model.notificationsAllowed == true)
        #expect(model.isScheduled)
        #expect(model.nextScanDate == Self.start.addingTimeInterval(7 * 86_400))
        #expect(await model.runIfDue() == false)
        h.clock.advance(days: 6.9)
        #expect(await model.runIfDue() == false)
        #expect(h.scan.calls == 0)

        // Changing weekly → monthly doesn't ask again.
        await model.setFrequency(.monthly)
        #expect(h.notifier.authorizationRequests == 1)
    }

    @Test func dueScanRecordsTheFindingAndNotifiesOnce() async throws {
        let h = makeHarness(bytes: 3_200_000_000)
        let model = makeModel(h)
        await model.setFrequency(.weekly)
        h.clock.advance(days: 7)
        #expect(await model.runIfDue() == true)
        #expect(h.scan.calls == 1)
        let finding = try #require(model.notice)
        #expect(finding.bytes == 3_200_000_000)
        #expect(finding.date == h.clock.now)
        #expect(h.notifier.posts.count == 1)
        #expect(h.notifier.posts.first?.title == ScanReminderModel.headline(for: finding))
        #expect(h.notifier.posts.first?.title.hasPrefix("About ") == true)
        #expect(h.notifier.posts.first?.title.hasSuffix(" can be cleaned") == true)

        // Not due again until a week after that scan.
        #expect(await model.runIfDue() == false)
        h.clock.advance(days: 6)
        #expect(await model.runIfDue() == false)
        h.clock.advance(days: 1)
        #expect(await model.runIfDue() == true)
        #expect(h.scan.calls == 2)

        // The result survives a relaunch.
        let relaunched = makeModel(h)
        #expect(relaunched.frequency == .weekly)
        #expect(relaunched.lastFinding?.bytes == 3_200_000_000)
    }

    @Test func smallFindingsOnlyUpdateTheNotice() async {
        let h = makeHarness(bytes: 200_000_000)
        let model = makeModel(h)
        await model.setFrequency(.weekly)
        h.clock.advance(days: 7)
        #expect(await model.runIfDue() == true)
        #expect(model.notice?.bytes == 200_000_000)
        #expect(h.notifier.posts.isEmpty)
    }

    @Test func nothingFoundShowsNothing() async {
        let h = makeHarness(bytes: 0)
        let model = makeModel(h)
        await model.setFrequency(.monthly)
        h.clock.advance(days: 31)
        #expect(await model.runIfDue() == true)
        #expect(model.lastFinding?.bytes == 0)
        #expect(model.notice == nil)
        #expect(h.notifier.posts.isEmpty)
    }

    @Test func waitsWhileTheUserIsScanningOrCleaning() async {
        let h = makeHarness()
        var busy = true
        let model = makeModel(h, isBusy: { busy })
        await model.setFrequency(.weekly)
        h.clock.advance(days: 7)
        #expect(await model.runIfDue() == false)
        #expect(h.scan.calls == 0)
        // The timer sleeps until the retry instead of spinning.
        #expect(abs((model.sleepDelay() ?? 0) - 15 * 60) < 0.01)
        busy = false
        h.clock.advance(seconds: 60)
        #expect(await model.runIfDue() == false)
        h.clock.advance(seconds: 15 * 60)
        #expect(await model.runIfDue() == true)
        #expect(h.scan.calls == 1)
    }

    @Test func timerRunsADueScanOnItsOwn() async throws {
        let h = makeHarness()
        let first = makeModel(h)
        await first.setFrequency(.weekly)
        h.clock.advance(days: 8)
        // A later launch: the scan is already due, so the timer runs it without anyone calling runIfDue.
        let model = makeModel(h)
        model.start()
        defer { model.stop() }
        for _ in 0..<200 where model.notice == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(h.scan.calls == 1)
        #expect(model.notice != nil)
        #expect(model.isScheduled)
    }

    @Test func sleepIsCappedAndNeverNegative() async {
        let h = makeHarness()
        let model = makeModel(h)
        #expect(model.sleepDelay() == nil)
        await model.setFrequency(.weekly)
        #expect(model.sleepDelay() == 3_600)
        h.clock.advance(days: 30)
        #expect(model.sleepDelay() == 0)
    }

    @Test func dismissingHidesTheNoticeUntilTheNextScan() async {
        let h = makeHarness()
        let model = makeModel(h)
        await model.setFrequency(.weekly)
        h.clock.advance(days: 7)
        await model.runIfDue()
        #expect(model.notice != nil)
        model.dismissNotice()
        #expect(model.notice == nil)
        #expect(makeModel(h).notice == nil)
        h.clock.advance(days: 7)
        await model.runIfDue()
        #expect(model.notice != nil)
    }

    @Test func turningOffStopsTheTimerAndHidesTheNotice() async {
        let h = makeHarness()
        let model = makeModel(h)
        model.start()
        defer { model.stop() }
        await model.setFrequency(.weekly)
        h.clock.advance(days: 7)
        await model.runIfDue()
        #expect(model.notice != nil)
        await model.setFrequency(.off)
        #expect(!model.isScheduled)
        #expect(model.notice == nil)
        h.clock.advance(days: 30)
        #expect(await model.runIfDue() == false)
        #expect(h.scan.calls == 1)
    }

    @Test func deniedNotificationsStillShowTheNotice() async {
        let h = makeHarness(allow: false)
        let model = makeModel(h)
        await model.setFrequency(.weekly)
        #expect(model.notificationsAllowed == false)
        h.clock.advance(days: 7)
        #expect(await model.runIfDue() == true)
        #expect(model.notice != nil)
    }

    /// The real background scan: sums only what Smart Scan selects by default and removes nothing.
    @Test func backgroundScanIsReadOnlyAndCountsDefaultSelection() async throws {
        let home = try TempDirectory()
        let cache = try home.file("Library/Caches/com.example/blob", bytes: 40_960)
        let download = try home.file("Downloads/old.dmg", bytes: 40_960)
        let rules = try FixtureRules.writeDirectory(in: home)
        let coordinator = OpenCleanCoordinator(
            home: home.path, environment: ["OPENCLEAN_RULES_DIR": rules], registry: ProbeRegistry([]),
            processChecker: FakeProcessChecker(), openFiles: FakeOpenFiles(), admin: FakeAdminExecutor(),
            fullDiskAccess: { .granted }, trash: { _ in nil })
        let finding = await ScanReminderModel.backgroundScan(coordinator: coordinator)()
        // fixture.caches (regenerable) counts; fixture.downloads (review) does not.
        #expect(finding.itemCount == 1)
        #expect(finding.bytes > 0)
        #expect(FileManager.default.fileExists(atPath: cache))
        #expect(FileManager.default.fileExists(atPath: download))
        #expect(coordinator.history().isEmpty)
    }
}
