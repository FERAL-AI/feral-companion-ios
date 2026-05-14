import SwiftUI

/// SwiftUI host that renders the current onboarding step inside a
/// FeralTheme background with a progress indicator and navigation.
struct OnboardingHost: View {
    @ObservedObject var controller: OnboardingController
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        ZStack {
            FeralTheme.bgDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                if controller.currentStep != .complete {
                    progressBar
                        .padding(.top, FeralTheme.padMD)
                        .padding(.horizontal, FeralTheme.padXL)
                }

                Spacer(minLength: 0)

                stepContent
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                    .animation(FeralTheme.springSnappy, value: controller.currentStep)

                Spacer(minLength: 0)

                if controller.currentStep.isSkippable {
                    Button("Skip") {
                        controller.skip()
                    }
                    .font(.subheadline)
                    .foregroundStyle(FeralTheme.textTertiary)
                    .padding(.bottom, FeralTheme.padLG)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Progress dots

    private var progressBar: some View {
        HStack(spacing: 8) {
            ForEach(0..<OnboardingStep.progressStepCount, id: \.self) { index in
                Capsule()
                    .fill(index <= controller.currentStep.rawValue
                          ? FeralTheme.accent
                          : FeralTheme.surface2)
                    .frame(height: 4)
                    .animation(FeralTheme.springSnappy, value: controller.currentStep)
            }
        }
        .frame(height: 4)
    }

    // MARK: - Step router

    @ViewBuilder
    private var stepContent: some View {
        switch controller.currentStep {
        case .welcome:
            WelcomeStepView(onContinue: { controller.advance() })

        case .brainDiscover:
            BrainDiscoverStepView(controller: controller)

        case .brainPair:
            // After discovery selects a brain, we auto-advance past
            // this step via BrainDiscoverStepView. If the user
            // reaches it via back-nav, show discovery again.
            BrainDiscoverStepView(controller: controller)

        case .iosPermissions:
            PermissionsStepView(onContinue: { controller.advance() })

        case .blePairing:
            PeripheralsStepView(onContinue: { controller.advance() })

        case .macTCC:
            MacPermissionsStepView(onContinue: { controller.advance() })

        case .complete:
            CompletionStepView(controller: controller)
        }
    }
}
