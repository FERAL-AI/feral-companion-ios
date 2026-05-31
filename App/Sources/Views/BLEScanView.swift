import SwiftUI

/// Modal that drives the JieLi BLE scan/connect lifecycle for the
/// Theora glasses. Uses `JWBleSession` (singleton) as the source of
/// truth for discovered peripherals + connection phase.
///
/// When the proprietary JWBle SDK is absent, shows an unavailable
/// message instead of attempting scan/connect.
struct BLEScanView: View {
    @EnvironmentObject var env: AppEnvironment
    @StateObject private var session = JWBleSession.shared
    @Binding var isPresented: Bool

    /// Capability id this scan is for (e.g. `jw_health_glasses`).
    /// On `SyncSuccess` we activate this capability so HUP emits start.
    let capabilityId: String

    /// Display name shown in the sheet header.
    let title: String

    var body: some View {
        if JWBleSession.isSDKAvailable {
            scanContent
        } else {
            sdkUnavailableContent
        }
    }

    private var sdkUnavailableContent: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(.secondary)
                Text(JWBleSession.sdkUnavailableReason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Text("The app builds and runs without proprietary hardware SDKs. Contact Theora to obtain the JWBle framework bundle, then drop it into Vendor/ and run ./scripts/bootstrap.sh.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { isPresented = false }
                }
            }
        }
    }

    private var scanContent: some View {
        NavigationStack {
            VStack(spacing: 0) {
                phaseHeader
                    .padding(.horizontal)
                    .padding(.top, 8)

                if session.discovered.isEmpty {
                    emptyState
                } else {
                    deviceList
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        session.stopScan()
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isScanning {
                        Button("Stop") { session.stopScan() }
                    } else {
                        Button("Rescan") { session.startScanOnly() }
                    }
                }
            }
        }
        .onAppear {
            session.installCallbacksIfNeeded()
            session.startScanOnly()
        }
        .onDisappear {
            session.stopScan()
        }
        .onChange(of: session.phase) { phase in
            if case .ready = phase {
                env.devices.activate(capabilityId)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    isPresented = false
                }
            }
        }
    }

    private var isScanning: Bool {
        if case .scanning = session.phase { return true }
        return false
    }

    @ViewBuilder
    private var phaseHeader: some View {
        switch session.phase {
        case .idle:
            Label("Ready", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
        case .scanning:
            Label("Scanning for \(title)…", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.green)
        case .connecting(let name):
            Label("Connecting to \(name)…", systemImage: "link")
                .foregroundStyle(.yellow)
        case .ready(let name):
            Label("Connected: \(name)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .multilineTextAlignment(.leading)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Searching for nearby glasses…")
                .font(.callout).foregroundStyle(.secondary)
            Text("Make sure the glasses are charged and the lid is open. Bluetooth must be on.")
                .font(.caption2).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deviceList: some View {
        List(session.discovered) { entry in
            Button {
                session.connect(entry)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.body.weight(.semibold))
                        if let mac = entry.macAddress {
                            Text(mac).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Text("\(entry.rssi) dBm")
                        .font(.caption2.monospaced())
                        .foregroundStyle(rssiColor(entry.rssi))
                }
            }
            .buttonStyle(.plain)
            .disabled(isConnectingOther(entry: entry))
        }
        .listStyle(.plain)
    }

    private func isConnectingOther(entry: JWBleSession.Discovered) -> Bool {
        if case .connecting(let name) = session.phase, name != entry.name { return true }
        return false
    }

    private func rssiColor(_ rssi: Int) -> Color {
        if rssi >= -60 { return .green }
        if rssi >= -75 { return .yellow }
        return .orange
    }
}
