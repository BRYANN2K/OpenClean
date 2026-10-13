import Foundation
import Observation

public enum OnboardingStep: Int, CaseIterable, Sendable, Identifiable {
    case welcome, smartScan, safety, uninstaller, spaceLens, performance, fullDiskAccess, done

    public var id: Int { rawValue }

    /// Steps that explain a feature; all must be seen before onboarding can finish.
    public var isFeature: Bool {
        switch self {
        case .smartScan, .safety, .uninstaller, .spaceLens, .performance: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .welcome: String(localized: "Welcome", bundle: .appModel)
        case .smartScan: String(localized: "Smart Scan", bundle: .appModel)
        case .safety: String(localized: "Safe by design", bundle: .appModel)
        case .uninstaller: String(localized: "Uninstaller", bundle: .appModel)
        case .spaceLens: String(localized: "Space Lens", bundle: .appModel)
        case .performance: String(localized: "Performance", bundle: .appModel)
        case .fullDiskAccess: String(localized: "Full Disk Access", bundle: .appModel)
        case .done: String(localized: "All set", bundle: .appModel)
        }
    }
}

/// First-launch onboarding. It is complete only when every feature step has been seen and Full Disk
/// Access is granted; there is no skip. Completion is remembered per onboarding version.
@MainActor
@Observable
public final class OnboardingModel {
    public static let completedKey = "onboarding.completedVersion"
    /// Bump to show onboarding again after a release that changes it.
    public static let currentVersion = 1

    public private(set) var step: OnboardingStep = .welcome
    public private(set) var visited: Set<OnboardingStep> = [.welcome]
    public private(set) var isCompleted: Bool

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        isCompleted = defaults.integer(forKey: Self.completedKey) >= Self.currentVersion
    }

    public var featuresSeen: Bool {
        OnboardingStep.allCases.filter(\.isFeature).allSatisfy(visited.contains)
    }

    /// Continue is blocked on the Full Disk Access step until access is granted.
    public func canAdvance(accessGranted: Bool) -> Bool {
        switch step {
        case .done: false
        case .fullDiskAccess: accessGranted
        default: true
        }
    }

    public func canFinish(accessGranted: Bool) -> Bool {
        featuresSeen && accessGranted
    }

    public func next(accessGranted: Bool) {
        guard canAdvance(accessGranted: accessGranted),
            let following = OnboardingStep(rawValue: step.rawValue + 1)
        else { return }
        move(to: following)
    }

    public func back() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        move(to: previous)
    }

    /// Jumps to a step already seen (the progress dots); never skips ahead.
    public func go(to target: OnboardingStep) {
        guard visited.contains(target) else { return }
        move(to: target)
    }

    /// Finishes onboarding if its criteria are met. Returns whether it finished.
    @discardableResult
    public func finish(accessGranted: Bool) -> Bool {
        guard canFinish(accessGranted: accessGranted) else { return false }
        isCompleted = true
        defaults.set(Self.currentVersion, forKey: Self.completedKey)
        return true
    }

    /// Shows the tour again (Help → Welcome Tour). Finishing it again restores the completed state.
    public func restart() {
        step = .welcome
        visited = [.welcome]
        isCompleted = false
    }

    private func move(to target: OnboardingStep) {
        step = target
        visited.insert(target)
    }
}
