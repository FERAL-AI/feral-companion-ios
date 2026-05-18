import SwiftUI

/// Onboarding step 2: discover a FERAL brain on the local network
/// via mDNS, QR scan, or manual entry.
struct BrainDiscoverStepView: View {
    @ObservedObject var controller: OnboardingController
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var discovery = BrainDiscovery()
    @State private var pairFlow: BrainPairFlow?
    @State private var showManualEntry = false
    @State private var manualHost = ""
    @State private var manualPort = "9090"
    @State private var showQRScanner = false

    var body: some View {
        VStack(spacing: FeralTheme.padLG) {
            headerSection

            if discovery.authorization == .denied {
                localNetworkDeniedBanner
            } else if discovery.authorization == .undetermined && discovery.isScanning {
                permissionPendingHint
            }

            if discovery.authorization == .granted && discovery.isScanning && discovery.discovered.isEmpty {
                scanningIndicator
            }

            if !discovery.discovered.isEmpty {
                discoveredBrainsList
            }

            Divider()
                .background(FeralTheme.hairline)
                .padding(.horizontal, FeralTheme.padXL)

            alternativeMethodsSection

            if let error = pairFlow?.error {
                Text(prettifyPairError(error))
                    .font(.caption)
                    .foregroundStyle(FeralTheme.stateError)
                    .padding(.horizontal, FeralTheme.padXL)
            }

            if pairFlow?.isPairing == true {
                HStack(spacing: FeralTheme.padSM) {
                    ProgressView()
                        .tint(FeralTheme.accent)
                    Text("Connecting to brain…")
                        .font(.subheadline)
                        .foregroundStyle(FeralTheme.textSecondary)
                }
            }
        }
        .padding(.vertical, FeralTheme.padXL)
        .onAppear {
            if pairFlow == nil {
                pairFlow = BrainPairFlow(env: env)
            }
            discovery.startScan()
        }
        .onDisappear {
            discovery.stopScan()
        }
        .onChange(of: scenePhase) { phase in
            // User likely toggled Settings -> Privacy & Security -> Local
            // Network. Re-probe so the banner clears (or stays) without
            // forcing a back-out + retry of the onboarding step.
            if phase == .active {
                discovery.refreshAuthorization()
            }
        }
        .onChange(of: pairFlow?.succeeded) { success in
            if success == true {
                controller.advance()
            }
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerView { scanned in
                showQRScanner = false
                Task {
                    await ensurePairFlow().pairFromRaw(scanned)
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Subviews

    private var headerSection: some View {
        VStack(spacing: FeralTheme.padSM) {
            Image(systemName: "wifi")
                .font(.system(size: 40))
                .foregroundStyle(FeralTheme.accent)

            Text("Find your brain")
                .font(.title2.bold())
                .foregroundStyle(FeralTheme.textPrimary)

            Text("Make sure your Mac is running the FERAL brain on the same Wi-Fi network.")
                .font(.subheadline)
                .foregroundStyle(FeralTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, FeralTheme.padXL)
        }
    }

    private var scanningIndicator: some View {
        VStack(spacing: FeralTheme.padMD) {
            ProgressView()
                .tint(FeralTheme.accent)
                .scaleEffect(1.2)
            Text("Scanning local network…")
                .font(.subheadline)
                .foregroundStyle(FeralTheme.textTertiary)
        }
        .frame(height: 120)
    }

    /// Surfaced when iOS has denied Local Network access. Without this,
    /// the pair flow blows up with `-1009 "Internet connection appears
    /// to be offline"`, which is a lie — Wi-Fi is fine, the permission
    /// gate is what blocked the request.
    private var localNetworkDeniedBanner: some View {
        VStack(alignment: .leading, spacing: FeralTheme.padSM) {
            HStack(spacing: FeralTheme.padSM) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(FeralTheme.stateError)
                Text("FERAL doesn't have Local Network permission")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FeralTheme.textPrimary)
            }
            Text("iOS is blocking FERAL from reaching the brain on your Wi-Fi. Open Settings, enable Local Network for FERAL, then return here.")
                .font(.caption)
                .foregroundStyle(FeralTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openLocalNetworkSettings()
            } label: {
                Label("Open Settings", systemImage: "gear")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FeralTheme.padSM)
            }
            .buttonStyle(.borderedProminent)
            .tint(FeralTheme.accent)
        }
        .padding(FeralTheme.padMD)
        .feralGlass()
        .padding(.horizontal, FeralTheme.padXL)
    }

    private var permissionPendingHint: some View {
        HStack(spacing: FeralTheme.padSM) {
            ProgressView()
                .tint(FeralTheme.accent)
            Text("Requesting Local Network permission…")
                .font(.caption)
                .foregroundStyle(FeralTheme.textTertiary)
        }
        .padding(.horizontal, FeralTheme.padXL)
    }

    private var discoveredBrainsList: some View {
        ScrollView {
            LazyVStack(spacing: FeralTheme.padSM) {
                ForEach(discovery.discovered) { brain in
                    Button {
                        selectBrain(brain)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(brain.name)
                                    .font(.headline)
                                    .foregroundStyle(FeralTheme.textPrimary)
                                Text("\(brain.host):\(brain.port)")
                                    .font(FeralTheme.fontMonoCaption)
                                    .foregroundStyle(FeralTheme.textTertiary)
                            }
                            Spacer()
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.title3)
                                .foregroundStyle(FeralTheme.accent)
                        }
                        .padding(FeralTheme.padMD)
                        .feralGlass()
                    }
                }
            }
            .padding(.horizontal, FeralTheme.padXL)
        }
        .frame(maxHeight: 240)
    }

    private var alternativeMethodsSection: some View {
        VStack(spacing: FeralTheme.padMD) {
            Button {
                showQRScanner = true
            } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FeralTheme.padSM)
            }
            .buttonStyle(.bordered)
            .tint(FeralTheme.accent)
            .padding(.horizontal, FeralTheme.padXL)

            DisclosureGroup("Enter manually", isExpanded: $showManualEntry) {
                VStack(spacing: FeralTheme.padSM) {
                    TextField("Host (e.g. 192.168.1.42)", text: $manualHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .padding(FeralTheme.padSM)
                        .feralGlass(.thin)

                    TextField("Port", text: $manualPort)
                        .keyboardType(.numberPad)
                        .font(.body.monospaced())
                        .padding(FeralTheme.padSM)
                        .feralGlass(.thin)

                    Button("Connect") {
                        connectManually()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FeralTheme.accent)
                    .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, FeralTheme.padSM)
            }
            .foregroundStyle(FeralTheme.textSecondary)
            .padding(.horizontal, FeralTheme.padXL)
        }
    }

    // MARK: - Actions

    private func ensurePairFlow() -> BrainPairFlow {
        if let flow = pairFlow { return flow }
        let flow = BrainPairFlow(env: env)
        pairFlow = flow
        return flow
    }

    private func selectBrain(_ brain: DiscoveredBrain) {
        let flow = ensurePairFlow()
        discovery.resolve(brain) { host, port in
            Task {
                await flow.pairWithDiscovered(host: host, port: port)
            }
        }
    }

    private func connectManually() {
        let host = manualHost.trimmingCharacters(in: .whitespaces)
        let port = Int(manualPort) ?? 9090
        guard !host.isEmpty else { return }
        let flow = ensurePairFlow()
        Task {
            await flow.pairWithDiscovered(host: host, port: port)
        }
    }

    private func openLocalNetworkSettings() {
        // UIApplication.openSettingsURLString deep-links into our app's
        // own Settings page, which on iOS 16+ shows the Local Network
        // toggle inline. iOS does not expose a public URL for the
        // global Privacy -> Local Network list; this is the closest.
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Replace the misleading iOS-default "The Internet connection
    /// appears to be offline" copy with a precise message when the real
    /// cause is the Local Network permission gate. The pair HTTP client
    /// already detects this and surfaces a clear string, but third-party
    /// URL errors that pre-date the gate detection still propagate the
    /// raw `URLError.notConnectedToInternet` description.
    private func prettifyPairError(_ raw: String) -> String {
        let needles = [
            "Internet connection appears to be offline",
            "The network connection was lost",
            "Could not connect to the server",
        ]
        if needles.contains(where: { raw.localizedCaseInsensitiveContains($0) }) {
            return "Couldn't reach the brain on your Wi-Fi. If you just installed FERAL, allow Local Network access when iOS asks. Otherwise open Settings -> Privacy & Security -> Local Network and enable FERAL."
        }
        return raw
    }
}
