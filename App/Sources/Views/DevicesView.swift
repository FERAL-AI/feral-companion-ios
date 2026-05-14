import SwiftUI
import AVFoundation

/// "Devices" tab — the platform play. Lists every adapter the app
/// knows about, grouped by integration class (iPhone built-ins,
/// BLE devices, HealthKit-mediated). Tapping toggles activation.
struct DevicesView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var bleScanCapability: String? = nil
    @State private var bleScanTitle: String = ""

    @StateObject private var audioBridge = W300AudioBridge.shared

    var body: some View {
        List {
            // Phase 10 (audit-r10 overhaul) — at-a-glance answer to
            // "what does the brain see right now?". Polls
            // `/api/capabilities` (Phase 5) every 5s while this tab
            // is open. Closes the operator complaint that the iOS
            // app didn't surface the brain's network of nodes.
            BrainNetworkSection()

            // Phase 6 / audit-r8 brief #03 — show the live audio
            // route so the user sees whether voice is actually
            // routed via the W300 vs the iPhone speaker. No more
            // "voice working through the glasses" with the iPhone
            // speaker still owning the route.
            Section {
                AudioRouteRow(snapshot: audioBridge.currentRoute,
                              lastReason: audioBridge.lastRouteChangeReason)
            } header: {
                HStack {
                    Image(systemName: "waveform.circle")
                    Text("AUDIO ROUTE")
                        .font(.caption.bold())
                        .tracking(1)
                }
            } footer: {
                Text("Live AVAudioSession route. Updates when iOS picks a different input/output (W300 connect/disconnect, AirPods, car BT, etc.).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ForEach(DeviceStore.Entry.Category.allCases, id: \.rawValue) { category in
                let entries = env.devices.entries.filter { $0.category == category }
                if !entries.isEmpty {
                    Section {
                        ForEach(entries) { entry in
                            DeviceRow(entry: entry, onConnect: { handleConnect(entry) })
                        }
                    } header: {
                        HStack {
                            Image(systemName: category.icon)
                            Text(category.rawValue.uppercased())
                                .font(.caption.bold())
                                .tracking(1)
                        }
                    } footer: {
                        Text(footerFor(category))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
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
                title: bleScanTitle
            )
            .environmentObject(env)
        }
    }

    /// Triggered by a row "Connect" button. Bluetooth entries open
    /// the scan/connect modal because activation alone is just a
    /// pipe-open — the user must explicitly choose a peripheral.
    /// Non-Bluetooth entries activate immediately (HealthKit triggers
    /// the iOS permission sheet; iphone_camera primes audio session).
    private func handleConnect(_ entry: DeviceStore.Entry) {
        if entry.category == .bluetooth {
            bleScanTitle = entry.displayName
            bleScanCapability = entry.id
        } else {
            env.devices.activate(entry.id)
        }
    }

    private func footerFor(_ category: DeviceStore.Entry.Category) -> String {
        switch category {
        case .iphoneBuiltin:
            return "Always available. No external hardware required."
        case .bluetooth:
            return "Direct BLE pairing. Each vendor needs its iOS framework dropped into this app build."
        case .healthKitMediated:
            return "Universal path. Anything that syncs to Apple Health (Apple Watch, Whoop, Garmin, Fitbit, Oura, Polar, etc.) works through this single integration."
        }
    }
}

/// Wrapper so a single capability id can drive a `.sheet(item:)` —
/// String alone doesn't conform to Identifiable.
private struct BLEScanCap: Identifiable {
    let id: String
}

private struct AudioRouteRow: View {
    let snapshot: W300AudioBridge.RouteSnapshot
    let lastReason: AVAudioSession.RouteChangeReason?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Output")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Text(snapshot.outputName)
                    .font(.callout.weight(.medium))
                Spacer()
                if snapshot.isA2DPOutput {
                    Text("A2DP").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(.green)
                }
            }
            HStack {
                Text("Input")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Text(snapshot.inputName)
                    .font(.callout.weight(.medium))
                Spacer()
                if snapshot.isBluetoothHeadset {
                    Text("BT")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.18), in: Capsule())
                        .foregroundStyle(.blue)
                }
            }
            if let reason = lastReason {
                Text("Last change: \(reasonLabel(reason))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func reasonLabel(_ r: AVAudioSession.RouteChangeReason) -> String {
        switch r {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "new device available"
        case .oldDeviceUnavailable: return "device removed"
        case .categoryChange: return "category change"
        case .override: return "override"
        case .wakeFromSleep: return "wake from sleep"
        case .noSuitableRouteForCategory: return "no suitable route"
        case .routeConfigurationChange: return "config change"
        @unknown default: return "other"
        }
    }
}

private struct DeviceRow: View {
    @EnvironmentObject var env: AppEnvironment
    let entry: DeviceStore.Entry
    let onConnect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayName).font(.body.weight(.semibold))
                Text(entry.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                statusLabel
            }
            Spacer()
            actionButton
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch entry.status {
        case .available:
            Text("Ready to connect").font(.caption2).foregroundStyle(.tertiary)
        case .active:
            Label("Active", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
        case .connecting:
            Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption2).foregroundStyle(.yellow)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange).lineLimit(2)
        case .unsupported(let reason):
            Label(reason, systemImage: "wrench.and.screwdriver")
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch entry.status {
        case .available:
            Button(connectLabel) { onConnect() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .active:
            // `deactivate` is the single writer for Bluetooth row
            // teardown — it removes intent, drops the adapter, and
            // also calls `JWBleSession.disconnect()` for BT caps so
            // the radio link is torn down. We don't poke the session
            // directly here.
            Button("Disconnect", role: .destructive) {
                env.devices.deactivate(entry.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .connecting:
            // Surface a stop affordance while the BLE handshake is
            // in flight so the user can bail out cleanly.
            Button("Cancel", role: .destructive) {
                env.devices.deactivate(entry.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .failed:
            Button("Retry") { onConnect() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .unsupported:
            Text("Soon").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var connectLabel: String {
        entry.category == .bluetooth ? "Scan & connect" : "Connect"
    }
}
