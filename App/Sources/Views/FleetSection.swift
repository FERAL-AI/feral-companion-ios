import SwiftUI

// HUP fleet section — the "self-describing hardware hub" made visible.
//
// Every card here is rendered ENTIRELY from the brain's
// `/api/hardware/fleet` response: the device's name, its capabilities,
// their safety tiers, and the live honesty-loop verdict ("verified ✓" /
// "verified ✗" / "unverified"). Nothing about any specific device is
// hardcoded in this view — plug a new device into the brain and a new
// card appears, with the right controls and badges, no app change.
//
// Additive: lives alongside `BrainNetworkSection` (routable node actions)
// and the local `DeviceStore` rows (the phone's own adapters/pairing).

struct FleetSection: View {
    @StateObject private var store = FleetStore()
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        Section {
            if store.devices.isEmpty {
                FleetEmptyRow(lastError: store.lastRefreshError)
            } else {
                ForEach(store.devices) { device in
                    FleetDeviceCard(device: device)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                Text("HARDWARE FLEET (HUP)")
                    .font(.caption.bold())
                    .tracking(1)
                Spacer()
                if store.lastRefreshAt != nil {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
        } footer: {
            Text(
                "Self-describing devices the brain controls. Each card is "
                + "built from the device's own capability manifest — controls, "
                + "safety tiers, and the live honesty loop (firmware ack vs. "
                + "device telemetry). A new device appears here automatically."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .onAppear {
            store.bind(to: env.brain)
            store.start()
        }
        .onDisappear { store.stop() }
    }
}

private struct FleetDeviceCard: View {
    let device: FleetDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon(for: device.deviceType))
                    .foregroundStyle(.green)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(device.deviceType.uppercased())
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        if !device.connectionType.isEmpty {
                            Text("· \(device.connectionType)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        if !device.location.isEmpty {
                            Text("· \(device.location)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                Text("\(device.capabilities.count) cap\(device.capabilities.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Live honesty strip — the differentiator.
            if let v = device.lastVerified {
                HonestyStrip(verification: v)
            }

            // Server-driven controls/capabilities with safety badges.
            ForEach(device.capabilities) { cap in
                FleetCapabilityRow(cap: cap)
            }
        }
        .padding(.vertical, 4)
    }

    private func icon(for kind: String) -> String {
        switch kind.lowercased() {
        case "robot", "actuator": return "gearshape.2"
        case "glasses": return "eyeglasses"
        case "wearable", "wristband": return "applewatch"
        case "phone": return "iphone"
        case "camera": return "camera"
        case "speaker", "audio": return "hifispeaker"
        default: return "cpu"
        }
    }
}

private struct HonestyStrip: View {
    let verification: FleetVerification

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.caption2)
            Text("\(verification.capability): \(verification.verdict)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            if let observed = verification.observed, verification.verified == false {
                Text("(saw \(observed))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var symbol: String {
        switch verification.verified {
        case .some(true): return "checkmark.seal.fill"
        case .some(false): return "exclamationmark.triangle.fill"
        case .none: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch verification.verified {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return verification.success ? .orange : .red
        }
    }
}

private struct FleetCapabilityRow: View {
    let cap: FleetCapability

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: cap.readOnly ? "dot.radiowaves.up.forward" : "bolt.fill")
                .font(.caption2)
                .foregroundStyle(cap.readOnly ? .blue : .primary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(cap.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if !cap.paramNames.isEmpty {
                    Text(cap.paramNames.joined(separator: ", "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            SafetyBadge(cap: cap)
        }
    }
}

private struct SafetyBadge: View {
    let cap: FleetCapability

    var body: some View {
        HStack(spacing: 4) {
            if !cap.reversible {
                badge("irreversible", .red)
            }
            badge(label, tint)
        }
    }

    private var label: String {
        if cap.requiresApproval { return "approval" }
        if cap.requiresConfirmation || cap.safetyTier == "confirm" { return "confirm" }
        if cap.readOnly { return "read" }
        return "safe"
    }

    private var tint: Color {
        switch label {
        case "approval": return .red
        case "confirm": return .orange
        case "read": return .blue
        default: return .green
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct FleetEmptyRow: View {
    let lastError: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No hardware in the brain's fleet yet")
                    .font(.body.weight(.medium))
                if let lastError {
                    Text(lastError)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text("Plug a USB robot into the brain, or connect glasses / a wristband — it self-describes and appears here.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
