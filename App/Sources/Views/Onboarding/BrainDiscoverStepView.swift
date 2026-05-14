import SwiftUI

/// Onboarding step 2: discover a FERAL brain on the local network
/// via mDNS, QR scan, or manual entry.
struct BrainDiscoverStepView: View {
    @ObservedObject var controller: OnboardingController
    @EnvironmentObject var env: AppEnvironment
    @StateObject private var discovery = BrainDiscovery()
    @State private var pairFlow: BrainPairFlow?
    @State private var showManualEntry = false
    @State private var manualHost = ""
    @State private var manualPort = "9090"
    @State private var showQRScanner = false

    var body: some View {
        VStack(spacing: FeralTheme.padLG) {
            headerSection

            if discovery.isScanning && discovery.discovered.isEmpty {
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
                Text(error)
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
}
