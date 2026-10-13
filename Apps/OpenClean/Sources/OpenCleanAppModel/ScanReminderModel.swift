import Foundation
import Observation
import OpenCleanKit
import RuleKit
import ScanEngine

// Scheduled scan reminder: an opt-in (off by default) read-only Smart Scan that runs in the background
// once a week or once a month while OpenClean (or its menu bar item) is running, then says how much can
// be cleaned: a quiet notice in the menu bar popover and, if allowed, one local notification. It never
// cleans anything: the background scan has no path to `execute`, and its result is only a number.

/// How often the background scan runs.
public enum ScanReminderFrequency: String, CaseIterable, Identifiable, Sendable {
    case off, weekly, monthly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Off"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }
}

/// What a background scan found: only what a Smart Scan would select by default (regenerable items).
public struct ScanReminderFinding: Equatable, Sendable {
    public var date: Date
    public var bytes: Int64
    public var itemCount: Int

    public init(date: Date, bytes: Int64, itemCount: Int) {
        self.date = date
        self.bytes = bytes
        self.itemCount = itemCount
    }
}

/// When the next background scan is due. Pure, so it is tested with fixed dates.
///
/// The anchor is the later of "turned on" and "last background scan", so turning the reminder on never
/// starts a scan right away: the first one runs a week (or a month) later. An anchor in the future (the
/// clock was set back) counts as now, so a wrong clock can't push the scan years away.
public struct ScanReminderSchedule: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func nextScan(frequency: ScanReminderFrequency, enabledAt: Date?, lastScan: Date?, now: Date) -> Date? {
        guard let anchor = [enabledAt, lastScan].compactMap({ $0 }).max() else { return nil }
        let start = min(anchor, now)
        switch frequency {
        case .off: return nil
        case .weekly: return calendar.date(byAdding: .day, value: 7, to: start)
        case .monthly: return calendar.date(byAdding: .month, value: 1, to: start)
        }
    }

    public func isDue(frequency: ScanReminderFrequency, enabledAt: Date?, lastScan: Date?, now: Date) -> Bool {
        guard let next = nextScan(frequency: frequency, enabledAt: enabledAt, lastScan: lastScan, now: now) else {
            return false
        }
        return next <= now
    }
}

/// Reminder preferences, kept in `UserDefaults` like `UpdateSettingsStore`: they belong to the app only
/// (the CLI never runs in the background), so they stay out of the shared `settings.json`.
///
/// - `scanReminder.frequency`: off (default), weekly or monthly.
/// - `scanReminder.enabledAt`: when it was last turned on (the first scan is one period later).
/// - `scanReminder.lastScan`: when the last background scan finished.
/// - `scanReminder.lastBytes` / `lastItems`: what it found.
/// - `scanReminder.noticeDismissed`: the menu bar notice for that result was dismissed.
public final class ScanReminderSettingsStore: @unchecked Sendable {
    public static let frequencyKey = "scanReminder.frequency"
    public static let enabledAtKey = "scanReminder.enabledAt"
    public static let lastScanKey = "scanReminder.lastScan"
    public static let lastBytesKey = "scanReminder.lastBytes"
    public static let lastItemsKey = "scanReminder.lastItems"
    public static let noticeDismissedKey = "scanReminder.noticeDismissed"

    let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var frequency: ScanReminderFrequency {
        get { defaults.string(forKey: Self.frequencyKey).flatMap(ScanReminderFrequency.init) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: Self.frequencyKey) }
    }

    public var enabledAt: Date? {
        get { defaults.object(forKey: Self.enabledAtKey) as? Date }
        set { defaults.set(newValue, forKey: Self.enabledAtKey) }
    }

    public var lastFinding: ScanReminderFinding? {
        get {
            guard let date = defaults.object(forKey: Self.lastScanKey) as? Date else { return nil }
            return ScanReminderFinding(
                date: date, bytes: Int64(defaults.integer(forKey: Self.lastBytesKey)),
                itemCount: defaults.integer(forKey: Self.lastItemsKey))
        }
        set {
            defaults.set(newValue?.date, forKey: Self.lastScanKey)
            defaults.set(newValue.map { Int($0.bytes) }, forKey: Self.lastBytesKey)
            defaults.set(newValue?.itemCount, forKey: Self.lastItemsKey)
        }
    }

    public var noticeDismissed: Bool {
        get { defaults.bool(forKey: Self.noticeDismissedKey) }
        set { defaults.set(newValue, forKey: Self.noticeDismissedKey) }
    }
}

/// Local notifications. The app's implementation uses UserNotifications; tests use a fake.
public protocol ScanReminderNotifying: Sendable {
    /// Asks macOS for permission (shows the system prompt the first time). True when allowed.
    func requestAuthorization() async -> Bool
    /// Whether notifications are currently allowed, without prompting.
    func isAuthorized() async -> Bool
    func post(title: String, body: String) async
}

@MainActor
@Observable
public final class ScanReminderModel {
    public private(set) var frequency: ScanReminderFrequency
    public private(set) var lastFinding: ScanReminderFinding?
    public private(set) var isScanning = false
    /// nil until known; false when the user turned notifications off for OpenClean.
    public private(set) var notificationsAllowed: Bool?
    @ObservationIgnored private var noticeDismissed: Bool

    /// A finding of at least this size is announced with a notification; smaller ones only update the
    /// menu bar notice, so the reminder stays quiet when there is little to clean.
    public let notificationThreshold: Int64
    /// How long to wait before trying again when a scan is due but the user is scanning or cleaning.
    public let busyRetryDelay: TimeInterval
    /// The longest the timer sleeps before looking at the clock again (sleep/wake, clock changes).
    public let maxSleep: TimeInterval

    @ObservationIgnored private let settings: ScanReminderSettingsStore
    @ObservationIgnored private let schedule: ScanReminderSchedule
    @ObservationIgnored private let scan: @Sendable () async -> ScanReminderFinding
    @ObservationIgnored private let notifier: any ScanReminderNotifying
    @ObservationIgnored private let isBusy: @MainActor () -> Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var postponedUntil: Date?
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    /// - Parameters:
    ///   - scan: a read-only scan returning what a Smart Scan would select by default
    ///     (`backgroundScan(coordinator:)` in the app).
    ///   - isBusy: true while the user's own scan or cleanup runs; the background scan waits for it.
    public init(
        settings: ScanReminderSettingsStore, scan: @escaping @Sendable () async -> ScanReminderFinding,
        notifier: any ScanReminderNotifying, isBusy: @escaping @MainActor () -> Bool = { false },
        schedule: ScanReminderSchedule = ScanReminderSchedule(), notificationThreshold: Int64 = 1_000_000_000,
        busyRetryDelay: TimeInterval = 15 * 60, maxSleep: TimeInterval = 60 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settings = settings
        self.scan = scan
        self.notifier = notifier
        self.isBusy = isBusy
        self.schedule = schedule
        self.notificationThreshold = notificationThreshold
        self.busyRetryDelay = busyRetryDelay
        self.maxSleep = maxSleep
        self.now = now
        frequency = settings.frequency
        lastFinding = settings.lastFinding
        noticeDismissed = settings.noticeDismissed
    }

    // MARK: Settings

    /// Turning it on asks for notification permission (the only time OpenClean asks) and schedules the
    /// first scan one period from now. Turning it off stops the timer and hides the notice.
    public func setFrequency(_ newValue: ScanReminderFrequency) async {
        guard newValue != frequency else { return }
        let wasOff = frequency == .off
        frequency = newValue
        settings.frequency = newValue
        if newValue == .off {
            dismissNotice()
            reschedule()
            return
        }
        if wasOff { settings.enabledAt = now() }
        reschedule()
        if wasOff { notificationsAllowed = await notifier.requestAuthorization() }
    }

    public var nextScanDate: Date? {
        schedule.nextScan(frequency: frequency, enabledAt: settings.enabledAt, lastScan: lastFinding?.date, now: now())
    }

    // MARK: Menu bar notice

    /// The finding the menu bar shows: the last background scan's, while the reminder is on, it found
    /// something and the user hasn't dismissed it.
    public var notice: ScanReminderFinding? {
        guard frequency != .off, !noticeDismissed, let lastFinding, lastFinding.bytes > 0 else { return nil }
        return lastFinding
    }

    public func dismissNotice() {
        noticeDismissed = true
        settings.noticeDismissed = true
    }

    /// "About 3.2 GB can be cleaned".
    public static func headline(for finding: ScanReminderFinding) -> String {
        "About \(ByteCountFormatter.string(fromByteCount: finding.bytes, countStyle: .file)) can be cleaned"
    }

    public static let notificationBody =
        "A background Smart Scan found it. Nothing was removed; open OpenClean to review and clean."

    // MARK: Lifecycle

    /// Starts the timer (only while the reminder is on). Safe to call more than once.
    public func start() {
        guard !started else { return }
        started = true
        if frequency != .off {
            if settings.enabledAt == nil { settings.enabledAt = now() }
            Task { notificationsAllowed = await notifier.isAuthorized() }
        }
        reschedule()
    }

    /// Stops the timer (tests; the app lives until quit).
    public func stop() {
        started = false
        scheduleTask?.cancel()
        scheduleTask = nil
    }

    /// True while the timer runs (tests).
    public var isScheduled: Bool { scheduleTask != nil }

    private func reschedule() {
        scheduleTask?.cancel()
        scheduleTask = nil
        guard started, frequency != .off else { return }
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.sleepDelay() else { return }
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
                guard !Task.isCancelled, let model = self else { return }
                await model.runIfDue()
            }
        }
    }

    /// Seconds until the timer should look again: the next due date (or the busy retry), capped at
    /// `maxSleep`. Never negative.
    func sleepDelay() -> TimeInterval? {
        guard let next = nextScanDate else { return nil }
        let wake = [next, postponedUntil].compactMap { $0 }.max() ?? next
        return min(max(wake.timeIntervalSince(now()), 0), maxSleep)
    }

    /// Runs the background scan if one is due and the user isn't scanning or cleaning. Returns true
    /// when it scanned. Read-only: it records a number and maybe posts one notification.
    @discardableResult
    public func runIfDue() async -> Bool {
        let current = now()
        guard frequency != .off, !isScanning,
            schedule.isDue(
                frequency: frequency, enabledAt: settings.enabledAt, lastScan: lastFinding?.date, now: current)
        else { return false }
        if let postponedUntil, postponedUntil > current { return false }
        if isBusy() {
            postponedUntil = current.addingTimeInterval(busyRetryDelay)
            return false
        }
        postponedUntil = nil
        isScanning = true
        var finding = await scan()
        isScanning = false
        // Turned off while scanning: forget the result.
        guard frequency != .off else { return false }
        finding.date = now()
        lastFinding = finding
        settings.lastFinding = finding
        noticeDismissed = false
        settings.noticeDismissed = false
        if finding.bytes >= notificationThreshold {
            await notifier.post(title: Self.headline(for: finding), body: Self.notificationBody)
        }
        return true
    }
}

extension ScanReminderModel {
    /// The app's background scan: the enabled rules (no caution rules) with the user's exclusions, summed
    /// over what Smart Scan selects by default. It only scans; nothing here can remove a file.
    public nonisolated static func backgroundScan(
        coordinator: OpenCleanCoordinator, now: @escaping @Sendable () -> Date = { Date() }
    ) -> @Sendable () async -> ScanReminderFinding {
        {
            let settings = coordinator.settingsStore.load()
            let rules = coordinator.loadRules(includeCaution: false).rules
            let result = await coordinator.scan(rules, settings: settings)
            let selected = DefaultSelection.paths(in: result)
            let items = result.rules.flatMap(\.items).filter { !$0.reportOnly && selected.contains($0.path) }
            return ScanReminderFinding(date: now(), bytes: items.reduce(0) { $0 + $1.size }, itemCount: items.count)
        }
    }
}
