import SwiftUI

/// Onboarding step 4: optional BLE peripheral pairing — Theora W300
/// glasses (HR/SpO2 + HUD) and Veepoo wristband (HR/SpO2 + ECG).
/// The user can skip this step entirely. 2026-06-05 demo prep:
/// the previous "W300 Wristband" label was incorrect (W300 is the
/// glasses platform; the wristband is Veepoo) and both rows opened
/// the same glasses-only BLE scan, so the operator could never pair
/// the wristband from onboarding. Each row now opens the BLE scan
/// scoped to its own capability id.
struct PeripheralsStepView: View {
    var onContinue: () -> Void
    @EnvironmentObject var env: AppEnvironment
    @State private var bleScanCapability: String? = nil

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

                Text("Optionally pair the Theora glasses or the Veepoo wristband. You can always do this later from the Devices tab.")
                    .font(.subheadline)
                    .foregroundStyle(FeralTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, FeralTheme.padXL)
            }

            VStack(spacing: FeralTheme.padMD) {
                Button {
                    bleScanCapability = "jw_health_glasses"
                } label: {
                    peripheralCard(
                        name: "Theora Glasses (W300)",
                        icon: "eyeglasses",
                        description: "BLE mic/speaker, heart rate, SpO2, body temp, UV, steps.",
                        isConnected: isGlassesConnected
                    )
                }
                .buttonStyle(.plain)

                Button {
                    bleScanCapability = "veepoo_wristband"
                } label: {
                    peripheralCard(
                        name: "Veepoo Wristband",
                        icon: "applewatch",
                        description: "Heart rate, SpO2, body temp, ECG over BLE.",
                        isConnected: isWristbandConnected
                    )
                }
                .buttonStyle(.plain)
            }
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
        .sheet(item: Binding(
            get: { bleScanCapability.map(BLEScanCap.init) },
            set: { newValue in bleScanCapability = newValue?.id }
        )) { cap in
            BLEScanView(
                isPresented: Binding(
                    get: { bleScanCapability != nil },
                    set: { if !$0 { bleScanCapability = nil } }
                ),
                capabilityId: cap.id,
                title: cap.id == "veepoo_wristband" ? "Veepoo Wristband" : "Theora Glasses"
            )
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

    @MainActor
    private var isGlassesConnected: Bool {
        if case .ready = JWBleSession.shared.phase { return true }
        return false
    }

    @MainActor
    private var isWristbandConnected: Bool {
        if case .ready = VeepooSession.shared.phase { return true }
        return false
    }
}

/// Wrapper so a single capability id can drive a `.sheet(item:)` —
/// String alone doesn't conform to Identifiable.
private struct BLEScanCap: Identifiable {
    let id: String
}
