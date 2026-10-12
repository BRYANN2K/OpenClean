import Foundation
import Testing

@testable import OpenCleanAppModel

@MainActor
struct OnboardingModelTests {
    func makeDefaults() -> UserDefaults {
        let suite = "openclean.onboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func walk(_ model: OnboardingModel, to step: OnboardingStep, granted: Bool) {
        while model.step != step { model.next(accessGranted: granted) }
    }

    @Test func startsAtWelcomeAndNotCompleted() {
        let model = OnboardingModel(defaults: makeDefaults())
        #expect(model.step == .welcome)
        #expect(!model.isCompleted)
        #expect(!model.featuresSeen)
    }

    @Test func fullDiskAccessStepBlocksUntilGranted() {
        let model = OnboardingModel(defaults: makeDefaults())
        walk(model, to: .fullDiskAccess, granted: false)
        model.next(accessGranted: false)
        #expect(model.step == .fullDiskAccess)
        model.next(accessGranted: true)
        #expect(model.step == .done)
    }

    @Test func finishingNeedsEveryFeatureSeenAndAccess() {
        let defaults = makeDefaults()
        let model = OnboardingModel(defaults: defaults)
        #expect(!model.finish(accessGranted: true))
        walk(model, to: .done, granted: true)
        #expect(!model.finish(accessGranted: false))
        #expect(model.finish(accessGranted: true))
        #expect(model.isCompleted)
        #expect(OnboardingModel(defaults: defaults).isCompleted)
    }

    @Test func dotsOnlyJumpToVisitedSteps() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.go(to: .spaceLens)
        #expect(model.step == .welcome)
        walk(model, to: .uninstaller, granted: false)
        model.go(to: .smartScan)
        #expect(model.step == .smartScan)
        model.go(to: .performance)
        #expect(model.step == .smartScan)
    }

    @Test func restartShowsTheTourAgainAndFinishingRestoresCompletion() {
        let defaults = makeDefaults()
        let model = OnboardingModel(defaults: defaults)
        walk(model, to: .done, granted: true)
        model.finish(accessGranted: true)
        model.restart()
        #expect(!model.isCompleted)
        #expect(model.step == .welcome)
        #expect(!model.featuresSeen)
    }

    @Test func olderCompletedVersionShowsOnboardingAgain() {
        let defaults = makeDefaults()
        defaults.set(OnboardingModel.currentVersion - 1, forKey: OnboardingModel.completedKey)
        #expect(!OnboardingModel(defaults: defaults).isCompleted)
    }
}
