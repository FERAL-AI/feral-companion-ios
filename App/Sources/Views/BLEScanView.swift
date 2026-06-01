import SwiftUI

/// Modal that drives BLE scan/connect for Theora glasses (JWBle) or
/// the Veepoo wristband. Routes to the correct session singleton based
/// on `capabilityId`.
struct BLEScanView: View {
    @EnvironmentObject var env: AppEnvironment
    @Binding var isPresented: Bool
    let capabilityId: String
    let title: String

    var body: some View {
        switch capabilityId {
        case "veepoo_wristband":
            VeepooScanSheet(isPresented: $isPresented, capabilityId: capabilityId, title: title)
                .environmentObject(env)
        default:
            JWBleScanSheet(isPresented: $isPresented, capabilityId: capabilityId, title: title)
                .environmentObject(env)
        }
    }
}

// MARK: - JWBle (Theora glasses)

private struct JWBleScanSheet: View {
    @EnvironmentObject var env: AppEnvironment
    @StateObject private var session = JWBleSession.shared
    @Binding var isPresented: Bool
    let capabilityId: String
    let title: String

    var body: some View {
        if JWBleSession.isSDKAvailable {
            scanContent
        } else {
            sdkUnavailableContent(reason: JWBleSession.sdkUnavailableReason)
        }
    }

    private var scanContent: some View {
        NavigationStack {
            VStack(spacing: 0) {
                phaseHeader
                    .padding(.horizontal)
                    .padding(.top, 8)

                if session.discovered.isEmpty {
                    emptyState(
                        hint: "Searching for nearby glasses…",
                        detail: "Make sure the glasses are charged and the lid is open. Bluetooth must be on."
                    )
                } else {
                    List(session.discovered) { entry in
                        Button { session.connect(entry) } label: {
                            deviceRow(name: entry.name, subtitle: entry.macAddress, rssi: entry.rssi)
                        }
                        .buttonStyle(.plain)
                        .disabled(isConnectingOther(name: entry.name))
                    }
                    .listStyle(.plain)
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
        .onDisappear { session.stopScan() }
        .onChange(of: session.phase) { phase in
            if case .ready = phase { onConnected() }
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
            Label("Ready", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
        case .scanning:
            Label("Scanning for \(title)…", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.green)
        case .connecting(let name):
            Label("Connecting to \(name)…", systemImage: "link").foregroundStyle(.yellow)
        case .ready(let name):
            Label("Connected: \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).multilineTextAlignment(.leading)
        }
    }

    private func isConnectingOther(name: String) -> Bool {
        if case .connecting(let connectingName) = session.phase, connectingName != name { return true }
        return false
    }

    private func sdkUnavailableContent(reason: String) -> some View {
        NavigationStack {
            unavailableBody(reason: reason)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { isPresented = false }
                    }
                }
        }
    }

    private func onConnected() {
        env.devices.activate(capabilityId)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            isPresented = false
        }
    }
}

// MARK: - Veepoo wristband

private struct VeepooScanSheet: View {
    @EnvironmentObject var env: AppEnvironment
    @StateObject private var session = VeepooSession.shared
    @Binding var isPresented: Bool
    let capabilityId: String
    let title: String

    var body: some View {
        if VeepooSession.isSDKAvailable {
            scanContent
        } else {
            sdkUnavailableContent(reason: VeepooSession.sdkUnavailableReason)
        }
    }

    private var scanContent: some View {
        NavigationStack {
            VStack(spacing: 0) {
                phaseHeader
                    .padding(.horizontal)
                    .padding(.top, 8)

                if session.discovered.isEmpty {
                    emptyState(
                        hint: "Searching for nearby wristbands…",
                        detail: "Make sure the wristband is charged and worn nearby. Bluetooth must be on."
                    )
                } else {
                    List(session.discovered) { entry in
                        Button { session.connect(entry) } label: {
                            deviceRow(name: entry.name, subtitle: entry.id, rssi: entry.rssi)
                        }
                        .buttonStyle(.plain)
                        .disabled(isConnectingOther(name: entry.name))
                    }
                    .listStyle(.plain)
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
        .onDisappear { session.stopScan() }
        .onChange(of: session.phase) { phase in
            if case .ready = phase { onConnected() }
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
            Label("Ready", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
        case .scanning:
            Label("Scanning for \(title)…", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.green)
        case .connecting(let name):
            Label("Connecting to \(name)…", systemImage: "link").foregroundStyle(.yellow)
        case .ready(let name):
            Label("Connected: \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).multilineTextAlignment(.leading)
        }
    }

    private func isConnectingOther(name: String) -> Bool {
        if case .connecting(let connectingName) = session.phase, connectingName != name { return true }
        return false
    }

    private func sdkUnavailableContent(reason: String) -> some View {
        NavigationStack {
            unavailableBody(reason: reason)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { isPresented = false }
                    }
                }
        }
    }

    private func onConnected() {
        env.devices.activate(capabilityId)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            isPresented = false
        }
    }
}

// MARK: - Shared helpers

@ViewBuilder
private func emptyState(hint: String, detail: String) -> some View {
    VStack(spacing: 14) {
        Image(systemName: "antenna.radiowaves.left.and.right.slash")
            .font(.system(size: 48, weight: .thin))
            .foregroundStyle(.secondary)
        Text(hint)
            .font(.callout).foregroundStyle(.secondary)
        Text(detail)
            .font(.caption2).foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

@ViewBuilder
private func deviceRow(name: String, subtitle: String?, rssi: Int) -> some View {
    HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.body.weight(.semibold))
            if let subtitle = subtitle {
                Text(subtitle).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
        }
        Spacer()
        Text("\(rssi) dBm")
            .font(.caption2.monospaced())
            .foregroundStyle(rssiColor(rssi))
    }
}

@ViewBuilder
private func unavailableBody(reason: String) -> some View {
    VStack(spacing: 16) {
        Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 48, weight: .thin))
            .foregroundStyle(.secondary)
        Text(reason)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        Text("The app builds and runs without proprietary hardware SDKs. Contact Theora for the vendor framework bundle, then drop it into Vendor/ and run ./scripts/bootstrap.sh.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

private func rssiColor(_ rssi: Int) -> Color {
    if rssi >= -60 { return .green }
    if rssi >= -75 { return .yellow }
    return .orange
}
