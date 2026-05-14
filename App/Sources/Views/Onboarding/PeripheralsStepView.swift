import SwiftUI

/// Onboarding step 4: optional BLE peripheral pairing (W300 wristband,
/// Theora glasses). The user can skip this step entirely.
struct PeripheralsStepView: View {
    var onContinue: () -> Void
    @EnvironmentObject var env: AppEnvironment
    @State private var showBLEScan = false

    var body: some View {
        VStack(spacing: FeralTheme.padXL) {
            Spacer()

            VStack(spacing: FeralTheme.padSM) {
                Image(systemName: "wave.3.right")
                    .font(.system(size: 40))
                    .foregroundStyle(FeralTheme.accent)

                Text("Connect peripherals")
                    .font(.title2.bold())
                    .foregroundStyle(FeralTheme.textPrimary)

                Text("Optionally pair a wristband or glasses. You can always do this later from the Devices tab.")
                    .font(.subheadline)
                    .foregroundStyle(FeralTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, FeralTheme.padXL)
            }

            VStack(spacing: FeralTheme.padMD) {
                peripheralCard(
                    name: "W300 Wristband",
                    icon: "applewatch",
                    description: "Heart rate, steps, and wrist-tap gestures.",
                    isConnected: isW300Connected
                )

                peripheralCard(
                    name: "Theora Glasses",
                    icon: "eyeglasses",
                    description: "HUD display and scene camera.",
                    isConnected: isGlassesConnected
                )
            }
            .padding(.horizontal, FeralTheme.padXL)

            Button {
                showBLEScan = true
            } label: {
                Label("Scan for devices", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FeralTheme.padSM)
            }
            .buttonStyle(.bordered)
            .tint(FeralTheme.accent)
            .padding(.horizontal, FeralTheme.padXL)

            Spacer()

            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FeralTheme.padMD)
            }
            .buttonStyle(.borderedProminent)
            .tint(FeralTheme.accent)
            .padding(.horizontal, FeralTheme.padXL)
            .padding(.bottom, FeralTheme.padLG)
        }
        .sheet(isPresented: $showBLEScan) {
            BLEScanView(isPresented: $showBLEScan, capabilityId: "jw_health_glasses", title: "Peripherals")
                .environmentObject(env)
        }
    }

    private func peripheralCard(name: String, icon: String, description: String, isConnected: Bool) -> some View {
        HStack(spacing: FeralTheme.padMD) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(isConnected ? FeralTheme.stateLive : FeralTheme.textTertiary)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(FeralTheme.textPrimary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(FeralTheme.textTertiary)
            }

            Spacer()

            Text(isConnected ? "Connected" : "Not paired")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isConnected ? FeralTheme.stateLive : FeralTheme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    (isConnected ? FeralTheme.stateLiveSoft : FeralTheme.surface1),
                    in: Capsule()
                )
        }
        .padding(FeralTheme.padMD)
        .feralGlass()
    }

    private var isW300Connected: Bool {
        if case .ready = JWBleSession.shared.phase { return true }
        return false
    }

    private var isGlassesConnected: Bool {
        // Theora glasses connection state from the shared BLE session
        false
    }
}
