import SwiftUI

/// Modal pairing sheet. Two paths: scan a QR (camera) or paste a
/// pair URL / `feral://` link. The decoded payload is handed to
/// `ConnectionStore.applyPairing(...)` and the sheet dismisses on
/// success.
struct PairingView: View {
    @EnvironmentObject var env: AppEnvironment
    @Binding var isPresented: Bool

    @State private var pasted: String = ""
    @State private var pin: String = ""
    @State private var showScanner = false
    @State private var inflight = false
    @State private var error: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    }
                } footer: {
                    Text("Opens the camera. Scan the QR shown by your FERAL brain dashboard.")
                }

                Section("Or paste a pair link") {
                    TextField("feral://pair?p=… or https://brain/pair?t=…", text: $pasted, axis: .vertical)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                }

                Section("PIN (only if your brain requires one)") {
                    TextField("6-digit PIN", text: $pin)
                        .keyboardType(.numberPad)
                }

                if let error = error {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if inflight {
                            ProgressView()
                        } else {
                            Text("Pair").bold()
                        }
                    }
                    .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty || inflight)
                }
            }
            .navigationTitle("Pair a brain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { scanned in
                    pasted = scanned
                    showScanner = false
                    Task { await submit() }
                }
                .ignoresSafeArea()
            }
        }
    }

    private func submit() async {
        error = nil
        guard let decoded = PairingClient.decode(pasted.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "Could not parse this pair link. Expected a feral:// link or https://<brain>/pair?t=…"
            return
        }
        inflight = true
        defer { inflight = false }
        await env.connection.applyPairing(decoded, pin: pin.isEmpty ? nil : pin)

        // Only proceed to connect if pair-complete actually succeeded.
        // Don't auto-dismiss on error — leave the sheet open so the
        // user sees what's wrong.
        switch env.connection.status {
        case .paired:
            await env.connection.connect()
            // Wait briefly for BrainClient to flip to .connected
            // (driven by node_ack on the WS). If we never get there,
            // surface the underlying error and stay on this sheet.
            for _ in 0..<10 {
                if env.brain.state.isConnected { break }
                if case .failed(let m) = env.brain.state {
                    error = m
                    return
                }
                if case .error(let m) = env.connection.status {
                    error = m
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms
            }
            if env.brain.state.isConnected {
                isPresented = false
            } else {
                error = "Paired with the brain, but the WebSocket didn't reach a node_ack within 3 seconds. Open Settings → Show debug log for details."
            }
        case .error(let m):
            error = m
        case .pairing(let m):
            error = "Still pairing: \(m). Try again."
        default:
            error = "Pairing returned an unexpected state: \(env.connection.status)"
        }
    }
}
