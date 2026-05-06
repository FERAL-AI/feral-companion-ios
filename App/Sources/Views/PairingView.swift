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
            error = "Could not parse this pair link. Expected feral://pair?p=… or https://<brain>/pair?t=…"
            return
        }
        inflight = true
        defer { inflight = false }
        await env.connection.applyPairing(decoded, pin: pin.isEmpty ? nil : pin)
        if case .paired = env.connection.status {
            await env.connection.connect()
            isPresented = false
        } else if case .error(let m) = env.connection.status {
            error = m
        }
    }
}
