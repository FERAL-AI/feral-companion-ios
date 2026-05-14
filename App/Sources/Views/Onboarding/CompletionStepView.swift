import SwiftUI

/// Final onboarding step: celebration screen with a "Start a chat"
/// CTA that dismisses the wizard and seeds the first chat.
struct CompletionStepView: View {
    @ObservedObject var controller: OnboardingController
    @EnvironmentObject var env: AppEnvironment
    @State private var showCheckmark = false

    var body: some View {
        VStack(spacing: FeralTheme.padXL) {
            Spacer()

            ZStack {
                Circle()
                    .fill(FeralTheme.stateLiveSoft)
                    .frame(width: 100, height: 100)

                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(FeralTheme.stateLive)
                    .scaleEffect(showCheckmark ? 1.0 : 0.3)
                    .opacity(showCheckmark ? 1.0 : 0.0)
                    .animation(FeralTheme.springGentle, value: showCheckmark)
            }

            VStack(spacing: FeralTheme.padSM) {
                Text("You're all set")
                    .font(.largeTitle.bold())
                    .foregroundStyle(FeralTheme.textPrimary)

                Text("Your brain is paired and ready. Say hello and see what FERAL can do.")
                    .font(.subheadline)
                    .foregroundStyle(FeralTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, FeralTheme.padXL)
            }

            Spacer()

            Button {
                startChat()
            } label: {
                Label("Start a chat", systemImage: "bubble.left.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FeralTheme.padMD)
            }
            .buttonStyle(.borderedProminent)
            .tint(FeralTheme.accent)
            .padding(.horizontal, FeralTheme.padXL)
            .padding(.bottom, FeralTheme.padXL)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(0.2)) {
                showCheckmark = true
            }
        }
    }

    private func startChat() {
        controller.markComplete()
        Task {
            try? await env.brain.sendChat("Say hello and tell me what you can do")
        }
    }
}
