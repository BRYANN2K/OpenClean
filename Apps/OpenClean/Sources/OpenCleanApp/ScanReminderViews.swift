import AppKit
import OpenCleanAppModel
import SwiftUI
import UserNotifications

/// Posts the scan reminder as a local notification. Only works inside OpenClean.app: outside a bundle
/// (`swift run`) UserNotifications has no app to attribute it to, so this does nothing there.
struct UserNotificationReminderNotifier: ScanReminderNotifying {
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert])) ?? false
    }

    func isAuthorized() async -> Bool {
        guard let center else { return false }
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    func post(title: String, body: String) async {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // One reminder at a time: a new result replaces the previous notification.
        let request = UNNotificationRequest(identifier: "openclean.scan-reminder", content: content, trigger: nil)
        try? await center.add(request)
    }
}

/// Settings → Scan reminder.
struct ScanReminderSettingsSection: View {
    @Environment(ScanReminderModel.self) private var reminder

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Scan reminder", systemImage: "calendar.badge.clock")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            VStack(spacing: 0) {
                row("Background Smart Scan", detail: scheduleDetail) {
                    Picker("", selection: frequency) {
                        ForEach(ScanReminderFrequency.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if let finding = reminder.lastFinding {
                    Divider().overlay(Theme.glassDivider)
                    row(
                        "Last background scan",
                        detail:
                            "\(formatRelativeDay(finding.date)): \(formatBytes(finding.bytes)) in \(finding.itemCount) items"
                    ) { EmptyView() }
                }
                if reminder.frequency != .off, reminder.notificationsAllowed == false {
                    Divider().overlay(Theme.glassDivider)
                    row("Notifications are off", detail: "The result shows only in the menu bar.") {
                        Button("Open Notification Settings") { openNotificationSettings() }
                            .buttonStyle(CapsuleButtonStyle())
                    }
                }
                Text(
                    "While OpenClean or its menu bar item is running, it scans in the background and tells you how much can be cleaned: in the menu bar, and with a notification when it's 1 GB or more. It never cleans by itself."
                )
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .glassPanel()
        }
    }

    private var frequency: Binding<ScanReminderFrequency> {
        Binding(
            get: { reminder.frequency },
            set: { newValue in Task { await reminder.setFrequency(newValue) } })
    }

    private var scheduleDetail: String {
        guard reminder.frequency != .off, let next = reminder.nextScanDate else {
            return "Off. Nothing runs in the background."
        }
        return "Next scan \(next.formatted(date: .abbreviated, time: .omitted)) or later, while OpenClean is running."
    }

    private func row(_ title: String, detail: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).lineLimit(1)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 52)
    }

    private func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.openclean"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The menu bar popover's quiet line about the last background scan. Shows nothing unless the reminder
/// is on, found something and wasn't dismissed.
struct ScanReminderNotice: View {
    @Environment(ScanReminderModel.self) private var reminder
    let review: () -> Void

    var body: some View {
        if let finding = reminder.notice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ScanReminderModel.headline(for: finding))
                        .font(.system(size: 12, weight: .semibold))
                    Text("Background Smart Scan, \(formatRelativeDay(finding.date)). Nothing was removed.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                    Button("Review") { review() }
                        .buttonStyle(CapsuleButtonStyle())
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
                Button {
                    reminder.dismissNotice()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .glassPanel(radius: 12)
        }
    }
}
