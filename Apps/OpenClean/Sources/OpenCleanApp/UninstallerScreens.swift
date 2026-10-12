import AppInventory
import OpenCleanAppModel
import Quarantine
import SwiftUI

// MARK: Idle (nothing loaded)

struct UninstallerIdleView: View {
    @Environment(UninstallerModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Orb(size: 200) {
                Image(systemName: "xmark.app")
                    .font(.system(size: 76, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Remove apps and what they leave behind")
                .font(.system(size: 30, weight: .bold))
                .padding(.top, 28)
            Text(
                "OpenClean lists your apps with their sizes. Nothing is removed until you confirm, and uninstalled apps can be restored from History."
            )
            .font(.system(size: 15))
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .frame(maxWidth: 480)
            .padding(.top, 10)
            Spacer(minLength: 24)
            Button("List Apps") { model.load() }
                .buttonStyle(GlassCircleButtonStyle())
                .keyboardShortcut(.defaultAction)
            Text("Reads your Applications folders only")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 12)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Loading

struct UninstallerLoadingView: View {
    @Environment(UninstallerModel.self) private var model

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
            .accessibilityLabel("Measuring apps")
            .accessibilityValue("\(Int(fraction * 100)) percent")

            Text("Measuring apps…")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 28)
            Text("\(Int(fraction * 100))%")
                .font(.system(size: 56, weight: .bold))
                .rollingNumber(Int(fraction * 100))
            if let progress = model.progress, progress.total > 0 {
                Text("\(progress.finished) of \(progress.total) apps measured")
                    .font(.system(size: 14))
                    .rollingNumber(progress.finished)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 24)
            Button("Stop") { model.stopLoading() }
                .buttonStyle(CapsuleButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Working

struct UninstallerWorkingView: View {
    @Environment(UninstallerModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            ZStack {
                ProgressRing(fraction: 0.22, lineWidth: 6)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(
                        reduceMotion ? nil : .linear(duration: 1.1).repeatForever(autoreverses: false),
                        value: spinning)
                Orb(size: 220) { LogoGlyph(size: 190) }
            }
            .frame(width: 264, height: 264)
            .onAppear { spinning = true }
            .accessibilityElement()
            .accessibilityLabel("Uninstalling")

            Text("Moving \(model.processedApp?.name ?? "the app") to quarantine…")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 28)
            Text(formatBytes(model.selectedBytes))
                .font(.system(size: 56, weight: .bold))
                .monospacedDigit()
            Text("\(model.processedApp?.name ?? "App") + \(leftoverCount(model.chosenLeftovers.count))")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 24)
            Text("Apps that are running, changed since the list was loaded, or in use are skipped automatically.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Complete

struct UninstallerCompleteView: View {
    @Environment(UninstallerModel.self) private var model
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let name = model.processedApp?.name ?? "The app"
        let days = appModel.settings.clampedRetentionDays
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Orb(size: 180) {
                Image(systemName: model.appWasRemoved ? "checkmark" : "exclamationmark")
                    .font(.system(size: 76, weight: .heavy))
                    .foregroundStyle(.white)
            }
            Group {
                if model.appWasRemoved, case .finished(let report) = model.outcome {
                    Text("\(name) was uninstalled")
                        .font(.system(size: 34, weight: .bold))
                        .padding(.top, 30)
                    Text(
                        "\(formatBytes(report.quarantinedBytes)) in quarantine for \(days) days. Restore it from History."
                    )
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 8)
                    skipped(report.manifest.skippedEntries)
                } else {
                    Text("\(name) was not uninstalled")
                        .font(.system(size: 34, weight: .bold))
                        .padding(.top, 30)
                    Text(failureReason)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.gold)
                        .lineLimit(3)
                        .padding(.top, 8)
                    Text("Nothing was moved.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 4)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 640)
            Spacer(minLength: 24)
            Button("Done") { model.done() }
                .buttonStyle(CapsuleButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 36)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }

    private var failureReason: String {
        if let message = model.errorMessage { return message }
        switch model.outcome {
        case .refused(let refusal): return sentence(refusal.description)
        case .finished(let report):
            return sentence(report.manifest.entries.first?.reason ?? "The app could not be moved.")
        case nil: return "The app could not be moved."
        }
    }

    private func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst() + (text.hasSuffix(".") ? "" : ".")
    }

    @ViewBuilder
    private func skipped(_ entries: [ManifestEntry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(entries.count) item\(entries.count == 1 ? " was" : "s were") skipped and left in place")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.gold)
                ForEach(entries.prefix(5)) { entry in
                    Text(
                        "\((entry.originalPath as NSString).abbreviatingWithTildeInPath) — \(entry.reason ?? "skipped")"
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                if entries.count > 5 {
                    Text("Details are in History.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel()
            .padding(.top, 20)
        }
    }
}
