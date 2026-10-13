import AppKit
import OpenCleanAppModel
import Permissions
import SwiftUI

/// First-launch tour: one screen per feature, then Full Disk Access, then a checklist. Shown instead of the
/// main window until `OnboardingModel.finish` succeeds.
struct OnboardingView: View {
    @Environment(OnboardingModel.self) private var onboarding
    @Environment(AppModel.self) private var app
    @Environment(AppNavigation.self) private var navigation

    private var granted: Bool { app.accessAdvice == .ok }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("Step \(onboarding.step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 20)
            .frame(height: 40)

            ZStack {
                page(for: onboarding.step)
                    .id(onboarding.step)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 64)

            footer
        }
        .foregroundStyle(.white)
        .background(backdrop.gradient.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.45), value: onboarding.step)
        .task(id: onboarding.step) {
            // Watch for the grant while the permission screens are showing.
            guard onboarding.step == .fullDiskAccess || onboarding.step == .done else { return }
            while !Task.isCancelled {
                app.refreshAccess()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private func page(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            OnboardingPage(
                eyebrow: nil, title: "Welcome to OpenClean",
                text:
                    "A transparent, open-source cleaner for your Mac. Take a quick look at what it does, then set up the one permission it needs."
            ) {
                WelcomeVisual()
            }
        case .smartScan:
            OnboardingPage(
                eyebrow: ("Smart Scan", Theme.accent), title: "One click finds the junk",
                text:
                    "Caches, logs, browser data and developer leftovers, found in seconds. Safe items are ticked for you, and nothing is removed until you press Clean."
            ) {
                SmartScanVisual()
            }
        case .safety:
            OnboardingPage(
                eyebrow: ("Safe by design", Theme.accent), title: "Every removal can be undone",
                text:
                    "Caches that rebuild themselves are deleted. Everything else goes to quarantine first, and History restores it for \(app.settings.clampedRetentionDays) days. Your documents and system files are always protected."
            ) {
                SafetyVisual()
            }
        case .uninstaller:
            OnboardingPage(
                eyebrow: ("Uninstaller", Color(hex: 0xD9B8FF)), title: "Remove apps and what they left behind",
                text:
                    "OpenClean finds an app's caches, preferences, containers and launch agents by its exact bundle ID. The whole uninstall goes to quarantine, so it can be restored."
            ) {
                UninstallerVisual()
            }
        case .spaceLens:
            OnboardingPage(
                eyebrow: ("Space Lens", Color(hex: 0x8FC4FF)), title: "See exactly where your space went",
                text:
                    "An interactive map of your disk, plus large & old files and duplicates. Nothing is pre-selected, and anything you remove goes to the Trash."
            ) {
                SpaceLensVisual()
            }
        case .performance:
            OnboardingPage(
                eyebrow: ("Performance", Theme.gold), title: "Keep an eye on your Mac",
                text:
                    "Live CPU and memory in the menu bar, heavy apps with Force Quit, login items, and one-click maintenance such as flushing the DNS cache."
            ) {
                PerformanceVisual()
            }
        case .fullDiskAccess:
            FullDiskAccessPage(granted: granted, advice: app.accessAdvice)
        case .done:
            DonePage(featuresSeen: onboarding.featuresSeen, granted: granted)
        }
    }

    private var footer: some View {
        HStack {
            HStack {
                if onboarding.step != .welcome {
                    Button("Back") { onboarding.back() }
                        .buttonStyle(CapsuleButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases) { step in
                    let seen = onboarding.visited.contains(step)
                    let current = step == onboarding.step
                    Button {
                        onboarding.go(to: step)
                    } label: {
                        Capsule()
                            .fill(current ? Theme.accent : .white.opacity(seen ? 0.6 : 0.22))
                            .frame(width: current ? 24 : 8, height: 8)
                            .contentShape(Rectangle().inset(by: -6))
                    }
                    .buttonStyle(.plain)
                    .disabled(!seen)
                    .accessibilityLabel("Step \(step.rawValue + 1): \(step.title)")
                    .accessibilityValue(current ? Text("current") : seen ? Text("visited") : Text("not visited yet"))
                }
            }
            .animation(.snappy(duration: 0.3), value: onboarding.step)

            HStack {
                if onboarding.step == .done {
                    Button("Go to Smart Scan") {
                        navigation.selection = .smartScan
                        onboarding.finish(accessGranted: granted)
                    }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .disabled(!onboarding.canFinish(accessGranted: granted))
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(
                        onboarding.step == .welcome ? String(localized: "Get started") : String(localized: "Continue")
                    ) {
                        onboarding.next(accessGranted: granted)
                    }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .disabled(!onboarding.canAdvance(accessGranted: granted))
                    .keyboardShortcut(.defaultAction)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 28)
        .frame(height: 76)
    }

    private var backdrop: Backdrop {
        switch onboarding.step {
        case .welcome, .smartScan: .scan
        case .safety, .done: .success
        case .uninstaller: .uninstaller
        case .spaceLens: .spaceLens
        case .performance: .performance
        case .fullDiskAccess: .history
        }
    }
}

/// Visual on top, eyebrow + title + one paragraph below, each fading up in turn.
struct OnboardingPage<Visual: View>: View {
    let eyebrow: (LocalizedStringKey, Color)?
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    @ViewBuilder var visual: Visual
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            visual.frame(height: 270)
            if let eyebrow {
                Text(eyebrow.0)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(eyebrow.1)
                    .padding(.top, 22)
                    .fadeUp(shown, delay: 0.08)
            }
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, eyebrow == nil ? 30 : 8)
                .fadeUp(shown, delay: 0.16)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 580)
                .padding(.top, 10)
                .fadeUp(shown, delay: 0.24)
        }
        .onAppear { shown = true }
    }
}

extension View {
    /// Fades and lifts into place once `shown` turns true; instant with Reduce Motion.
    func fadeUp(_ shown: Bool, delay: Double = 0) -> some View {
        modifier(FadeUp(shown: shown, delay: delay))
    }
}

private struct FadeUp: ViewModifier {
    let shown: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .animation(reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.15).delay(delay), value: shown)
    }
}

// MARK: Full Disk Access

struct FullDiskAccessPage: View {
    let granted: Bool
    let advice: AccessAdvice
    @State private var openedSettings = false
    @State private var shown = false

    var body: some View {
        HStack(spacing: 48) {
            SettingsMockVisual(granted: granted)
                .frame(width: 380)
                .fadeUp(shown)
            VStack(alignment: .leading, spacing: 14) {
                Text("One permission")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.accent)
                Text("Allow Full Disk Access").font(.system(size: 32, weight: .bold))
                Text(
                    "Trash, Mail, Safari and iOS backups live in folders macOS protects. OpenClean only reads what its cleaning rules list, and never sends anything off your Mac."
                )
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    stepRow(1, "Click **Open System Settings**.")
                    stepRow(
                        2,
                        advice == .regrantAfterRebuild
                            ? "OpenClean was updated: select it, remove it with **−**, then add it again."
                            : "Turn on **OpenClean** in the list, or drag its icon below into the list.")
                    stepRow(3, "Come back here. OpenClean notices on its own.")
                }
                HStack(spacing: 10) {
                    if !granted {
                        Button("Open System Settings") {
                            openedSettings = true
                            NSWorkspace.shared.open(FullDiskAccessChecker.settingsURL)
                        }
                        .buttonStyle(CapsuleButtonStyle(prominent: true))
                    }
                    StatusPill(granted: granted, waiting: openedSettings)
                }
                if !granted {
                    HStack(spacing: 10) {
                        AppIconView(size: 34)
                            .draggable(Bundle.main.bundleURL)
                            .help("Drag OpenClean into the Full Disk Access list")
                        Text("Drag this icon into the list if OpenClean isn't there.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .frame(width: 430, alignment: .leading)
            .fadeUp(shown, delay: 0.12)
        }
        .onAppear { shown = true }
    }

    private func stepRow(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.deepTeal)
                .frame(width: 20, height: 20)
                .background(Theme.accent, in: Circle())
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StatusPill: View {
    let granted: Bool
    let waiting: Bool

    var body: some View {
        HStack(spacing: 8) {
            if granted {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy))
            } else if waiting {
                ProgressView().controlSize(.mini).tint(Theme.gold)
            }
            Text(granted ? "Access granted" : waiting ? "Waiting for access…" : "Not allowed yet")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(granted ? Theme.deepTeal : waiting ? Theme.gold : Theme.textSecondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(
            granted ? Theme.accent : waiting ? Theme.gold.opacity(0.16) : Color.white.opacity(0.12), in: Capsule()
        )
        .animation(.snappy, value: granted)
        .accessibilityElement(children: .combine)
    }
}

// MARK: All set

struct DonePage: View {
    let featuresSeen: Bool
    let granted: Bool
    @AppStorage(MenuBarSettings.enabledKey) private var menuBarEnabled = true
    @Environment(UpdateModel.self) private var updates
    @State private var shown = false

    var body: some View {
        @Bindable var updates = updates
        VStack(spacing: 0) {
            Orb(size: 150) {
                CheckmarkShape()
                    .trim(from: 0, to: shown ? 1 : 0)
                    .stroke(.white, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                    .frame(width: 64, height: 64)
                    .animation(.easeOut(duration: 0.6).delay(0.3), value: shown)
            }
            .scaleEffect(shown ? 1 : 0.6)
            .opacity(shown ? 1 : 0)
            .animation(.spring(duration: 0.5, bounce: 0.35), value: shown)
            Text("You're all set").font(.system(size: 36, weight: .bold)).padding(.top, 28).fadeUp(shown, delay: 0.1)
            VStack(spacing: 0) {
                check("Explored Smart Scan, Uninstaller, Space Lens and Performance", ok: featuresSeen, delay: 0.3)
                Divider().overlay(Theme.glassDivider)
                check("Full Disk Access allowed", ok: granted, delay: 0.45)
                Divider().overlay(Theme.glassDivider)
                HStack(spacing: 12) {
                    Image(systemName: "menubar.rectangle").frame(width: 22)
                    Text("CPU and memory in the menu bar").font(.system(size: 14))
                    Spacer()
                    Toggle("CPU and memory in the menu bar", isOn: $menuBarEnabled)
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                Divider().overlay(Theme.glassDivider)
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle").frame(width: 22)
                    Text("Check for updates automatically").font(.system(size: 14))
                    Spacer()
                    Toggle("Check for updates automatically", isOn: $updates.autoCheck)
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
            }
            .frame(width: 480)
            .glassPanel()
            .padding(.top, 20)
            .fadeUp(shown, delay: 0.2)
            if !granted {
                Text("Full Disk Access was turned off. Go back one step to allow it again.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.gold)
                    .padding(.top, 10)
            }
        }
        .onAppear { shown = true }
    }

    private func check(_ label: LocalizedStringKey, ok: Bool, delay: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark" : "minus")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(Theme.deepTeal)
                .frame(width: 22, height: 22)
                .background(ok ? Theme.accent : .white.opacity(0.3), in: Circle())
                .scaleEffect(shown ? 1 : 0.2)
                .animation(.spring(duration: 0.45, bounce: 0.4).delay(delay), value: shown)
            Text(label).font(.system(size: 14))
            Spacer()
            Text(ok ? String(localized: "Done") : String(localized: "Pending")).font(.system(size: 12)).foregroundStyle(
                Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }
}

struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.54))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.76))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.84, y: rect.minY + rect.height * 0.28))
        return path
    }
}
