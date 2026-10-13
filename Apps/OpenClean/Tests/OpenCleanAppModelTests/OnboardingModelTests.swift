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

    @Test func reopeningResumesOnTheStepItWasQuitOn() {
        let defaults = makeDefaults()
        let model = OnboardingModel(defaults: defaults)
        walk(model, to: .fullDiskAccess, granted: false)

        let reopened = OnboardingModel(defaults: defaults)
        #expect(!reopened.isCompleted)
        #expect(reopened.step == .fullDiskAccess)
        #expect(reopened.featuresSeen)
        reopened.next(accessGranted: true)
        #expect(reopened.finish(accessGranted: true))
    }

    @Test func goingBackIsRememberedAndSeenStepsStayReachable() {
        let defaults = makeDefaults()
        let model = OnboardingModel(defaults: defaults)
        walk(model, to: .spaceLens, granted: false)
        model.go(to: .smartScan)

        let reopened = OnboardingModel(defaults: defaults)
        #expect(reopened.step == .smartScan)
        reopened.go(to: .spaceLens)
        #expect(reopened.step == .spaceLens)
        reopened.go(to: .performance)
        #expect(reopened.step == .spaceLens)
    }

    @Test func finishingOrRestartingClearsSavedProgress() {
        let defaults = makeDefaults()
        let model = OnboardingModel(defaults: defaults)
        walk(model, to: .done, granted: true)
        model.finish(accessGranted: true)
        #expect(defaults.object(forKey: OnboardingModel.stepKey) == nil)

        model.restart()
        walk(model, to: .safety, granted: false)
        model.restart()
        #expect(defaults.object(forKey: OnboardingModel.stepKey) == nil)
        #expect(defaults.object(forKey: OnboardingModel.visitedKey) == nil)
    }

    @Test func ignoresASavedStepItNeverSaw() {
        let defaults = makeDefaults()
        defaults.set(OnboardingStep.done.rawValue, forKey: OnboardingModel.stepKey)
        defaults.set([0, 99], forKey: OnboardingModel.visitedKey)
        let model = OnboardingModel(defaults: defaults)
        #expect(model.step == .welcome)
        #expect(model.visited == [.welcome])
    }

    @Test func olderCompletedVersionShowsOnboardingAgain() {
        let defaults = makeDefaults()
        defaults.set(OnboardingModel.currentVersion - 1, forKey: OnboardingModel.completedKey)
        #expect(!OnboardingModel(defaults: defaults).isCompleted)
    }
}
