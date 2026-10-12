import OpenCleanAppModel
import RuleKit
import SwiftUI

// Looping illustrations for the onboarding steps. Each one is decorative (hidden from VoiceOver; the
// page text carries the meaning) and holds a still, representative frame when Reduce Motion is on.

/// Runs a PhaseAnimator loop, or shows one still phase with Reduce Motion.
struct LoopingPhases<Phase: Equatable, Content: View>: View {
    let phases: [Phase]
    let still: Phase
    let animation: (Phase) -> Animation
    @ViewBuilder let content: (Phase) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            content(still)
        } else {
            PhaseAnimator(phases, content: content, animation: animation)
        }
    }
}

// MARK: Welcome

struct WelcomeVisual: View {
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size: CGFloat = 190
        Orb(size: size) {
            ZStack {
                LogoRing()
                    .trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(.white, style: StrokeStyle(lineWidth: LogoRing.lineWidth(for: 165), lineCap: .round))
                Spark().fill(.white).scaleEffect(drawn ? 1 : 0.01, anchor: UnitPoint(x: 0.716, y: 0.316))
                Spark(center: CGPoint(x: 0.85, y: 0.133), radius: 0.044)
                    .fill(.white.opacity(0.85))
                    .scaleEffect(drawn ? 1 : 0.01, anchor: UnitPoint(x: 0.85, y: 0.133))
            }
            .frame(width: 165, height: 165)
        }
        .scaleEffect(drawn ? 1 : 0.7)
        .opacity(drawn ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(duration: 1.1, bounce: 0.25)) { drawn = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Smart Scan

struct SmartScanVisual: View {
    @State private var spin = false
    @State private var shown = false
    @State private var found: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().stroke(.white.opacity(0.14), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 270 : -90))
                Orb(size: 168) {
                    VStack(spacing: 2) {
                        Text(found < 0.001 ? "0 KB" : formatBytes(Int64(found * 1_000_000_000)))
                            .font(.system(size: 28, weight: .bold))
                            .rollingNumber(Int(found * 10))
                        Text("found").font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .frame(width: 206, height: 206)
            HStack(spacing: 10) {
                ForEach(Array(RuleCategory.allCases.enumerated()), id: \.element) { index, category in
                    CategoryIcon(category: category, size: 32)
                        .scaleEffect(shown ? 1 : 0.2)
                        .opacity(shown ? 1 : 0)
                        .animation(
                            reduceMotion
                                ? nil : .spring(duration: 0.45, bounce: 0.45).delay(0.2 + Double(index) * 0.12),
                            value: shown)
                }
            }
        }
        .onAppear {
            shown = true
            guard !reduceMotion else {
                found = 18.6
                return
            }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { spin = true }
        }
        .task {
            guard !reduceMotion else { return }
            for tick in 1...25 {
                try? await Task.sleep(for: .milliseconds(90))
                let progress = Double(tick) / 25
                found = 18.6 * (1 - pow(1 - progress, 3))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Safe by design

private enum SafetyPhase: CaseIterable { case hidden, shown, removed, restored }

struct SafetyVisual: View {
    var body: some View {
        LoopingPhases(phases: SafetyPhase.allCases, still: .removed) { phase in
            switch phase {
            case .hidden: .easeOut(duration: 0.3).delay(0.6)
            case .shown: .spring(duration: 0.6, bounce: 0.2)
            case .removed: .easeInOut(duration: 0.7).delay(1.2)
            case .restored: .spring(duration: 0.7, bounce: 0.2).delay(0.8)
            }
        } content: { phase in
            HStack(spacing: 40) {
                VStack(alignment: .leading, spacing: 12) {
                    row("App caches", .user, .regenerable)
                        .opacity(phase == .shown ? 1 : 0)
                        .scaleEffect(phase == .shown ? 1 : 0.9)
                    row("Old simulators", .developer, .review)
                        .opacity(phase == .shown || phase == .restored ? 1 : 0)
                        .offset(x: phase == .removed ? 250 : phase == .hidden ? -20 : 0)
                        .scaleEffect(phase == .removed ? 0.55 : 1)
                    row("Mail downloads", .mail, .caution)
                        .opacity(phase == .shown ? 1 : 0)
                        .offset(x: phase == .removed || phase == .restored ? 250 : phase == .hidden ? -20 : 0)
                        .scaleEffect(phase == .removed || phase == .restored ? 0.55 : 1)
                    Label("Restored from History", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .opacity(phase == .restored ? 1 : 0)
                }
                .frame(width: 300)
                QuarantineBox(highlighted: phase == .removed || phase == .restored, size: 150)
            }
        }
        .accessibilityHidden(true)
    }

    private func row(_ name: String, _ category: RuleCategory, _ safety: SafetyLevel) -> some View {
        HStack(spacing: 10) {
            CategoryIcon(category: category, size: 26)
            Text(name).font(.system(size: 13, weight: .semibold))
            Spacer()
            SafetyTag(safety: safety)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .glassPanel(radius: 12)
    }
}

struct QuarantineBox: View {
    let highlighted: Bool
    var size: CGFloat = 150
    /// A short tray (icon and label side by side) for illustrations that need the vertical room.
    var compact = false

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox").font(.system(size: 18)).foregroundStyle(Theme.gold)
                    Text("Quarantine").font(.system(size: 13, weight: .semibold))
                }
                .frame(width: size, height: 56)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "archivebox").font(.system(size: size * 0.24)).foregroundStyle(Theme.gold)
                    Text("Quarantine").font(.system(size: 13, weight: .semibold))
                    Text("Undo for 7 days").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                .frame(width: size, height: size)
            }
        }
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.gold.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .shadow(color: Theme.gold.opacity(highlighted ? 0.45 : 0), radius: highlighted ? 14 : 0)
        .scaleEffect(highlighted ? 1.04 : 1)
    }
}

// MARK: Uninstaller

private enum GatherPhase: CaseIterable { case hidden, spread, gathered, dropped }

struct UninstallerVisual: View {
    private let chips: [(String, CGSize)] = [
        ("Caches", CGSize(width: -190, height: -50)), ("Preferences", CGSize(width: 190, height: -50)),
        ("Containers", CGSize(width: -200, height: 40)), ("Launch agent", CGSize(width: 200, height: 40)),
    ]

    var body: some View {
        LoopingPhases(phases: GatherPhase.allCases, still: .spread) { phase in
            switch phase {
            case .hidden: .easeOut(duration: 0.2).delay(0.5)
            case .spread: .spring(duration: 0.6, bounce: 0.25)
            case .gathered: .easeInOut(duration: 0.7).delay(1.0)
            case .dropped: .easeIn(duration: 0.6).delay(0.4)
            }
        } content: { phase in
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0xB48CFF), Color(hex: 0x6A3478)], startPoint: .top, endPoint: .bottom)
                    )
                    .overlay(Image(systemName: "app.dashed").font(.system(size: 34, weight: .medium)))
                    .frame(width: 80, height: 80)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 8)
                    .offset(y: phase == .dropped ? 96 : -20)
                    .scaleEffect(phase == .dropped ? 0.45 : 1)
                    .opacity(phase == .dropped || phase == .hidden ? 0 : 1)
                ForEach(chips, id: \.0) { chip in
                    Text(chip.0)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 92, height: 28)
                        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.22)))
                        .offset(
                            phase == .gathered
                                ? CGSize(width: 0, height: -20)
                                : phase == .dropped ? CGSize(width: 0, height: 96) : chip.1
                        )
                        .scaleEffect(phase == .gathered ? 0.6 : phase == .dropped ? 0.35 : 1)
                        .opacity(phase == .spread || phase == .gathered ? 1 : 0)
                }
                QuarantineBox(highlighted: phase == .dropped, size: 150, compact: true)
                    .offset(y: 96)
            }
            .frame(width: 520, height: 260)
        }
        .accessibilityHidden(true)
    }
}

// MARK: Space Lens

private enum DuplicatePhase: CaseIterable { case apart, together, trashed }

struct SpaceLensVisual: View {
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let inner: [Double] = [0.46, 0.30, 0.21]
    private let outer: [Double] = [0.28, 0.16, 0.22, 0.18]

    var body: some View {
        HStack(spacing: 56) {
            ZStack {
                ring(inner, diameter: 88, colorOffset: 0)
                ring(outer, diameter: 148, colorOffset: 3)
                Circle().fill(Theme.spaceMapCenter).frame(width: 56, height: 56)
                Text("Home").font(.system(size: 13, weight: .bold))
            }
            .frame(width: 220, height: 220)
            LoopingPhases(phases: DuplicatePhase.allCases, still: .together) { phase in
                switch phase {
                case .apart: .easeOut(duration: 0.3).delay(0.6)
                case .together: .spring(duration: 0.7, bounce: 0.2).delay(0.6)
                case .trashed: .easeInOut(duration: 0.6).delay(0.8)
                }
            } content: { phase in
                ZStack(alignment: .topLeading) {
                    fileCard("IMG_2041.heic", "Suggested to keep")
                    fileCard("IMG_2041 copy.heic", "Same content")
                        .offset(phase == .apart ? CGSize(width: 70, height: 26) : .zero)
                        .scaleEffect(phase == .trashed ? 0.6 : 1)
                        .opacity(phase == .trashed ? 0 : 1)
                    Label("Moved to Trash", systemImage: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .offset(x: 50, y: 86)
                        .opacity(phase == .trashed ? 1 : 0)
                        .scaleEffect(phase == .trashed ? 1 : 0.5)
                }
                .frame(width: 250, height: 150, alignment: .topLeading)
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(duration: 1.2, bounce: 0.1)) { grown = true }
        }
        .accessibilityHidden(true)
    }

    private func ring(_ shares: [Double], diameter: CGFloat, colorOffset: Int) -> some View {
        ZStack {
            ForEach(Array(shares.enumerated()), id: \.offset) { index, share in
                let start = shares.prefix(index).reduce(0, +) + 0.005 * Double(index)
                Circle()
                    .trim(from: start, to: start + share * (grown ? 1 : 0))
                    .stroke(
                        Theme.spaceMapPalette[(index + colorOffset) % Theme.spaceMapPalette.count],
                        style: StrokeStyle(lineWidth: 26))
            }
        }
        .frame(width: diameter, height: diameter)
        .rotationEffect(.degrees(-90))
    }

    private func fileCard(_ name: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x62BFFF), Color(hex: 0xB3A6FF)], startPoint: .topLeading,
                        endPoint: .bottomTrailing)
                )
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .frame(width: 180, alignment: .leading)
        .background(Color(hex: 0x28346E), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.18)))
    }
}

// MARK: Performance

struct PerformanceVisual: View {
    @Environment(PerformanceModel.self) private var model
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                    Text(formatPercent(model.cpu)).rollingNumber(formatPercent(model.cpu))
                    Image(systemName: "memorychip").padding(.leading, 4)
                    Text(formatPercent(model.memory?.usedFraction)).rollingNumber(
                        formatPercent(model.memory?.usedFraction))
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                Text(Date.now, format: .dateTime.weekday().hour().minute()).foregroundStyle(Theme.textSecondary)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 10) {
                bar("CPU", model.cpu)
                bar("Memory", model.memory?.usedFraction)
                OnboardingSparkline(values: model.cpuHistory.map(\.value))
                    .trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(Theme.accent, lineWidth: 2)
                    .frame(height: 34)
                HStack(spacing: 8) {
                    CategoryIcon(category: .browsers, size: 16)
                    Text("Browser")
                    Spacer()
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                }
                .font(.system(size: 12))
            }
            .padding(14)
            .frame(width: 290)
            .background(Color(hex: 0x28140A, opacity: 0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.16)))
        }
        .frame(width: 420, alignment: .trailing)
        .task { await model.monitor(.metrics) }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 1.2).delay(0.3)) { drawn = true }
        }
        .accessibilityHidden(true)
    }

    private func bar(_ label: String, _ fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                Spacer()
                Text(formatPercent(fraction)).rollingNumber(formatPercent(fraction))
            }
            .font(.system(size: 12))
            ProgressView(value: min(1, max(0, fraction ?? 0))).progressViewStyle(.linear).tint(Theme.accent)
                .animation(.easeOut(duration: 0.4), value: fraction)
        }
    }
}

/// Line through values scaled to the frame; a gentle placeholder wave until samples arrive.
struct OnboardingSparkline: Shape {
    var values: [Double]

    func path(in rect: CGRect) -> Path {
        let points = values.count >= 2 ? values : [0.3, 0.32, 0.25, 0.5, 0.4, 0.45, 0.7, 0.5, 0.4, 0.55, 0.45, 0.6]
        let low = points.min() ?? 0
        let span = max((points.max() ?? 1) - low, 0.01)
        var path = Path()
        for (index, value) in points.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(points.count - 1)
            let y = rect.maxY - rect.height * CGFloat((value - low) / span) * 0.9
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

// MARK: Full Disk Access illustration

private enum TogglePhase: CaseIterable { case off, pointing, on }

struct SettingsMockVisual: View {
    let granted: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color(hex: 0xFF5F57), Color(hex: 0xFEBC2E), Color(hex: 0x28C840)], id: \.self) { color in
                    Circle().fill(color).frame(width: 9, height: 9)
                }
                Text("Privacy & Security › Full Disk Access")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.leading, 8)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.white.opacity(0.06))
            VStack(spacing: 2) {
                appRow("Terminal", on: true)
                if granted {
                    appRow("OpenClean", on: true, highlighted: true)
                } else {
                    LoopingPhases(phases: TogglePhase.allCases, still: .off) { phase in
                        switch phase {
                        case .off: .easeOut(duration: 0.2).delay(0.8)
                        case .pointing: .easeInOut(duration: 0.8)
                        case .on: .spring(duration: 0.35, bounce: 0.3).delay(0.2)
                        }
                    } content: { phase in
                        appRow("OpenClean", on: phase == .on, highlighted: true)
                            .overlay(alignment: .trailing) {
                                Circle()
                                    .fill(.white.opacity(0.9))
                                    .frame(width: 14, height: 14)
                                    .shadow(color: .white.opacity(0.4), radius: 4)
                                    .offset(x: phase == .off ? -150 : -16, y: phase == .off ? 40 : 4)
                                    .opacity(phase == .off ? 0 : 1)
                            }
                    }
                }
                appRow("Backup Utility", on: false)
            }
            .padding(10)
        }
        .background(Color(hex: 0x1E1E22, opacity: 0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
        .accessibilityHidden(true)
    }

    private func appRow(_ name: String, on: Bool, highlighted: Bool = false) -> some View {
        HStack(spacing: 10) {
            if name == "OpenClean" {
                AppIconView(size: 22)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x3A3A3F)).frame(width: 22, height: 22)
            }
            Text(name).font(.system(size: 12, weight: highlighted ? .semibold : .regular))
            Spacer()
            Capsule()
                .fill(on ? Theme.accent : .white.opacity(0.22))
                .frame(width: 38, height: 20)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 14, height: 14).padding(3)
                }
        }
        .padding(8)
        .background(highlighted ? Theme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}
