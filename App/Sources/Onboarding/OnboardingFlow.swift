import Foundation
import SwiftUI

/// Steps in the first-run onboarding wizard.
///
/// Order matches the wizard progression; raw values are persisted to
/// UserDefaults so a kill mid-flow resumes at the right screen.
enum OnboardingStep: Int, CaseIterable, Comparable {
    case welcome = 0
    case brainDiscover = 1
    case brainPair = 2
    case iosPermissions = 3
    case blePairing = 4
    case macTCC = 5
    case complete = 6

    static func < (lhs: OnboardingStep, rhs: OnboardingStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Steps the user can skip without blocking subsequent steps.
    var isSkippable: Bool {
        switch self {
        case .blePairing: return true
        case .iosPermissions: return true
        case .macTCC: return true
        default: return false
        }
    }

    /// Total number of user-facing dots in the progress indicator.
    /// The `.complete` celebration screen doesn't count as a "step".
    static var progressStepCount: Int { OnboardingStep.complete.rawValue }
}

/// Drives the onboarding wizard's progression. Persists the current
/// step to UserDefaults so a kill mid-flow resumes correctly.
@MainActor
final class OnboardingController: ObservableObject {

    private static let currentStepKey = "feral.onboarding.currentStep"
    private static let completedKey = "feral.onboarding.completed"

    @Published var currentStep: OnboardingStep
    @Published private(set) var isComplete: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let completed = defaults.bool(forKey: Self.completedKey)
        self.isComplete = completed
        if completed {
            self.currentStep = .complete
        } else {
            let raw = defaults.integer(forKey: Self.currentStepKey)
            self.currentStep = OnboardingStep(rawValue: raw) ?? .welcome
        }
    }

    func advance() {
        guard let next = OnboardingStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
        persist()
        if next == .complete {
            markComplete()
        }
    }

    func goBack() {
        guard currentStep.rawValue > 0 else { return }
        currentStep = OnboardingStep(rawValue: currentStep.rawValue - 1) ?? .welcome
        persist()
    }

    func skip() {
        guard currentStep.isSkippable else { return }
        advance()
    }

    func markComplete() {
        isComplete = true
        defaults.set(true, forKey: Self.completedKey)
        defaults.set(OnboardingStep.complete.rawValue, forKey: Self.currentStepKey)
    }

    func reset() {
        isComplete = false
        currentStep = .welcome
        defaults.set(false, forKey: Self.completedKey)
        defaults.set(OnboardingStep.welcome.rawValue, forKey: Self.currentStepKey)
    }

    private func persist() {
        defaults.set(currentStep.rawValue, forKey: Self.currentStepKey)
    }
}
