import OpenCleanAppModel
import Quarantine
import RuleKit
import ScanEngine
import SwiftUI

struct SmartScanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .idle: ScanHomeView()
            case .scanning: ScanningView()
            case .results: ResultsView()
            case .cleaning: CleaningView()
            case .finished: CleanupCompleteView()
            }
        }
        .transition(.opacity)
    }
}

// MARK: Home

struct ScanHomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let stats = model.stats
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer()
                if let disk = model.disk {
                    StatPill(text: String(localized: "\(formatCapacity(disk.available)) free")) {
                        ProgressRing(fraction: disk.freeFraction, lineWidth: 2.5).frame(width: 13, height: 13)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Spacer(minLength: 16)
            Orb(size: 220) { LogoGlyph(size: 195) }
            Text(stats.cleanups == 0 ? "Let’s tidy up your Mac." : "Welcome back. Ready for another sweep?")
                .font(.system(size: 30, weight: .bold))
                .padding(.top, 28)
            Text(
                "Smart Scan looks for caches, logs and leftovers. Nothing is removed until you review it, and quarantined items can be restored for \(model.settings.clampedRetentionDays) days."
            )
            .font(.system(size: 15))
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 480)
            .layoutPriority(1)
            .padding(.top, 10)
            Spacer(minLength: 24)

            Button("Scan") { model.startScan() }
                .buttonStyle(GlassCircleButtonStyle())
                .keyboardShortcut(.defaultAction)
            Text(caption(stats))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 12)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
    }

    private func caption(_ stats: CleanupStats) -> String {
        guard let last = stats.lastCleanup else { return String(localized: "Press Return to start") }
        return String(localized: "Last cleanup \(last.formatted(.relative(presentation: .named)))")
    }
}

// MARK: Scanning

struct ScanningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let fraction = model.progress?.fraction ?? 0
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            ZStack {
                ProgressRing(fraction: fraction, lineWidth: 6)
                    .frame(width: 264, height: 264)
                    .animation(.easeOut(duration: 0.3), value: fraction)
                Orb(size: 220) { LogoGlyph(size: 190) }
            }
            .accessibilityElement()
            .accessibilityLabel("Scanning")
            .accessibilityValue("\(Int(fraction * 100)) percent")

            Text(currentLabel)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 28)
            Text("\(Int(fraction * 100))%")
                .font(.system(size: 56, weight: .bold))
                .rollingNumber(Int(fraction * 100))
            if let progress = model.progress {
                Text("\(progress.finished) of \(progress.total) rules checked")
                    .font(.system(size: 14))
                    .rollingNumber(progress.finished)
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 10) {
                ForEach(categories, id: \.self) { category in
                    CategoryIcon(category: category, size: 32)
                        .opacity(category == currentCategory ? 1 : 0.45)
                        .scaleEffect(category == currentCategory ? 1.12 : 1)
                        .animation(.spring(duration: 0.3), value: currentCategory)
                        .help(category.localizedName)
                }
            }
            .padding(14)
            .glassPanel()
            .padding(.top, 28)

            Spacer(minLength: 24)
            Button("Stop") { model.cancelScan() }
                .buttonStyle(CapsuleButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity)
    }

    private var categories: [RuleCategory] {
        let used = Set(model.loadedRules.rules.map(\.category))
        return RuleCategory.allCases.filter(used.contains)
    }

    private var currentCategory: RuleCategory? {
        guard let id = model.progress?.ruleID else { return nil }
        return model.loadedRules.rules.first { $0.id == id }?.category
    }

    private var currentLabel: String {
        guard let category = currentCategory else { return String(localized: "Starting scan…") }
        return String(localized: "Scanning \(category.localizedName)…")
    }
}

// MARK: Results

struct ResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Button {
                        model.startOver()
                    } label: {
                        Label("Start over", systemImage: "chevron.left")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Discard these results and go back. Nothing is removed.")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(headline)
                            .font(.system(size: 30, weight: .bold))
                        Text(
                            (model.result?.totalSize ?? 0) > 0
                                ? "Safe items are picked for you. Review items go to quarantine first, so you can undo."
                                : "Caches, logs and leftovers look tidy. Scan again any time."
                        )
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                    }
                    if let result = model.result, !result.isComplete {
                        Label(
                            "The scan was stopped early. Results are partial.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(Theme.gold)
                    }
                    if !found.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(found, id: \.category) { entry in
                                CategoryRow(category: entry.category, rules: entry.rules)
                                if entry.category != found.last?.category {
                                    Divider().overlay(Theme.glassDivider)
                                }
                            }
                        }
                        .glassPanel()
                    }
                    if !locked.isEmpty {
                        Label(
                            "\(ListFormatter.localizedString(byJoining: locked.map(\.localizedName))) can only be scanned with Full Disk Access.",
                            systemImage: "lock.fill"
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 16)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            CleanBar()
        }
    }

    private var categories: [(category: RuleCategory, rules: [RuleResult])] { model.result?.categories ?? [] }

    /// Categories with something removable; empty ones are left out rather than shown as "Zero KB".
    private var found: [(category: RuleCategory, rules: [RuleResult])] {
        categories.filter { entry in entry.rules.contains { $0.totalSize > 0 } }
    }

    /// Categories that found nothing because Full Disk Access is missing.
    private var locked: [RuleCategory] {
        categories
            .filter { entry in
                !entry.rules.contains { $0.totalSize > 0 }
                    && entry.rules.contains { $0.status == .needsFullDiskAccess }
            }
            .map(\.category)
    }

    private var headline: String {
        let total = model.result?.totalSize ?? 0
        return total > 0
            ? String(localized: "We found \(formatBytes(total)) to clean")
            : String(localized: "Nothing to clean right now")
    }
}

// MARK: Cleaning

/// Shown while a cleanup runs: the orb with a spinning accent arc and what is being cleaned.
struct CleaningView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        let plan = model.plan
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            ZStack {
                Circle().stroke(.white.opacity(0.16), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 270 : -90))
                    .animation(
                        reduceMotion ? nil : .linear(duration: 1.1).repeatForever(autoreverses: false),
                        value: spinning)
                Orb(size: 220) { LogoGlyph(size: 190) }
            }
            .frame(width: 264, height: 264)
            .onAppear { spinning = true }
            .accessibilityElement()
            .accessibilityLabel("Cleaning")

            Text("Cleaning…")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 28)
            Text(formatBytes(plan?.totalBytes ?? 0))
                .font(.system(size: 56, weight: .bold))
                .monospacedDigit()
            Text(
                splitSummary(now: plan?.immediateBytes ?? 0, quarantine: plan?.quarantineBytes ?? 0)
            )
            .font(.system(size: 14))
            .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 24)
            Text("Files that changed since the scan or are in use are skipped automatically.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity)
    }
}

struct CategoryRow: View {
    @Environment(AppModel.self) private var model
    let category: RuleCategory
    let rules: [RuleResult]

    var body: some View {
        let total = rules.reduce(Int64(0)) { $0 + $1.totalSize }
        let state = model.state(of: category)
        HStack(spacing: 14) {
            CheckboxButton(state: state, label: category.localizedName) {
                model.setSelected(state != .on, category: category)
            }
            CategoryIcon(category: category)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.localizedName).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if let safety {
                SafetyTag(safety: safety)
            }
            Text(formatBytes(total))
                .font(.system(size: 14))
                .monospacedDigit()
                .frame(minWidth: 80, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
        .onTapGesture { model.setSelected(state != .on, category: category) }
    }

    /// The most cautious safety level among rules that found something.
    private var safety: SafetyLevel? {
        let levels = rules.filter { $0.totalSize > 0 }.map(\.rule.safety)
        return SafetyLevel.allCases.last(where: levels.contains)
    }

    private var detail: String {
        let count = rules.flatMap(\.items).filter { !$0.reportOnly }.count
        let needsAccess = rules.filter { $0.status == .needsFullDiskAccess }.count
        var parts = [String(localized: "\(count) items")]
        if needsAccess > 0 { parts.append(String(localized: "\(needsAccess) need Full Disk Access")) }
        return parts.joined(separator: " · ")
    }
}

/// Bottom bar on the results screen: selection total and the round Clean button.
struct CleanBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let plan = model.plan
        let bytes = plan?.totalBytes ?? 0
        HStack(spacing: 28) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(bytes > 0 ? "\(formatBytes(bytes)) selected" : "Nothing selected")
                    .font(.system(size: 22, weight: .bold)).monospacedDigit()
                Text(
                    bytes > 0
                        ? splitSummary(now: plan?.immediateBytes ?? 0, quarantine: plan?.quarantineBytes ?? 0)
                        : String(localized: "Tick a category to clean it")
                )
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            ZStack {
                Button("Clean") { model.isReviewPresented = true }
                    .buttonStyle(GlassCircleButtonStyle(diameter: 96))
                    .disabled((plan?.isEmpty ?? true) || model.phase != .results)
            }

            VStack(alignment: .leading, spacing: 6) {
                Button("Scan Again") { model.startScan() }
                    .buttonStyle(CapsuleButtonStyle())
                    .disabled(model.phase == .cleaning)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
    }
}

// MARK: Complete

struct CleanupCompleteView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Orb(size: 180) {
                Image(systemName: "checkmark")
                    .font(.system(size: 76, weight: .heavy))
                    .foregroundStyle(.white)
            }
            if let report = model.lastReport {
                let freed = CleanupStats.freedBytes(report.manifest)
                Text("Your Mac is \(formatBytes(freed)) lighter")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.top, 30)
                Text(
                    splitSummary(
                        now: report.deletedBytes, quarantine: report.quarantinedBytes,
                        retentionDays: model.settings.clampedRetentionDays)
                )
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 8)
            }
            if let report = model.lastReport {
                OutcomeCards(
                    report: report, retentionDays: model.settings.clampedRetentionDays
                )
                .padding(.top, 28)
                if report.hadSkips {
                    SkippedItemsBanner(skipped: SkippedItems(report: report))
                        .layoutProbe("smartScan.skippedBanner")
                        .padding(.top, 14)
                }
            }
            Spacer(minLength: 24)
            HStack(spacing: 12) {
                Button("Done") { model.closeSummary() }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                if model.lastReport?.hadSkips != true {
                    Button("Scan Again") { model.startScan() }
                        .buttonStyle(CapsuleButtonStyle())
                }
            }
            .padding(.bottom, 36)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }
}

/// What a clean left in place and why, with the reasons in plain words and a way to scan again.
struct SkippedItemsBanner: View {
    @Environment(AppModel.self) private var model
    let skipped: SkippedItems
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.gold)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(skipped.headline).font(.system(size: 14, weight: .semibold))
                    Text(
                        skipped.suggestsRescan
                            ? String(localized: "\(skipped.summary) Scan again to pick them up.")
                            : skipped.summary
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Label(expanded ? "Hide details" : "Details", systemImage: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(CapsuleButtonStyle())
                Button("Scan Again") { model.startScan() }
                    .buttonStyle(CapsuleButtonStyle())
            }
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(skipped.groups) { group in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.explanation)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(2)
                                ForEach(group.paths.prefix(Self.pathsShown), id: \.self) { path in
                                    Text((path as NSString).abbreviatingWithTildeInPath)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                if group.paths.count > Self.pathsShown {
                                    Text("and \(group.paths.count - Self.pathsShown) more")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("Every item is also listed in History.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(14)
        .frame(maxWidth: 640)
        .glassPanel(radius: 14)
    }

    static let pathsShown = 4
}

struct OutcomeCards: View {
    let report: RemovalReport
    let retentionDays: Int

    var body: some View {
        HStack(spacing: 14) {
            card(symbol: "checkmark.circle.fill", tint: Theme.accent) {
                String(localized: "Freed now")
            } value: {
                formatBytes(report.deletedBytes)
            }
            card(symbol: "arrow.uturn.backward.circle.fill", tint: Theme.gold) {
                String(localized: "In quarantine")
            } value: {
                report.quarantinedBytes > 0
                    ? "\(formatBytes(report.quarantinedBytes)) · \(String(localized: "undo for \(retentionDays) days"))"
                    : String(localized: "Nothing")
            }
        }
        .frame(maxWidth: 640)
    }

    private func card(symbol: String, tint: Color, title: () -> String, value: () -> String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(title()).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Text(value()).font(.system(size: 16, weight: .bold)).monospacedDigit().lineLimit(2)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .glassPanel()
        .accessibilityElement(children: .combine)
    }
}

/// "X freed now · Y to quarantine", leaving out whichever side is zero.
func splitSummary(now: Int64, quarantine: Int64, retentionDays: Int? = nil) -> String {
    var parts: [String] = []
    if now > 0 || quarantine == 0 { parts.append(String(localized: "\(formatBytes(now)) freed now")) }
    if quarantine > 0 {
        parts.append(
            retentionDays.map {
                "\(String(localized: "\(formatBytes(quarantine)) in quarantine")) · \(String(localized: "undo for \($0) days"))"
            } ?? String(localized: "\(formatBytes(quarantine)) to quarantine"))
    }
    return parts.joined(separator: " · ")
}
