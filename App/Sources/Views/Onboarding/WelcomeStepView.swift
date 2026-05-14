import SwiftUI

/// First screen of the onboarding wizard. Explains FERAL in three
/// bullet points and invites the user to begin setup.
struct WelcomeStepView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: FeralTheme.padXL) {
            Spacer()

            Image(systemName: "brain.head.profile")
                .font(.system(size: 64))
                .foregroundStyle(FeralTheme.accent)
                .padding(.bottom, FeralTheme.padMD)

            Text("Welcome to FERAL")
                .font(.largeTitle.bold())
                .foregroundStyle(FeralTheme.textPrimary)

            VStack(alignment: .leading, spacing: FeralTheme.padLG) {
                bulletRow(
                    icon: "desktopcomputer",
                    text: "A personal AI brain that runs on your Mac and thinks alongside you."
                )
                bulletRow(
                    icon: "iphone",
                    text: "Your iPhone becomes a remote — voice, chat, and sensor bridge to the brain."
                )
                bulletRow(
                    icon: "link",
                    text: "Connect glasses, wristbands, and more to extend what FERAL can see and do."
                )
            }
            .padding(.horizontal, FeralTheme.padXL)

            Spacer()

            Button(action: onContinue) {
                Text("Get started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FeralTheme.padMD)
            }
            .buttonStyle(.borderedProminent)
            .tint(FeralTheme.accent)
            .padding(.horizontal, FeralTheme.padXL)
            .padding(.bottom, FeralTheme.padXL)
        }
    }

    private func bulletRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: FeralTheme.padMD) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(FeralTheme.accent)
                .frame(width: 28)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(FeralTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
