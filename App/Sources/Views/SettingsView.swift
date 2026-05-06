import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    @Binding var showPairingSheet: Bool

    var body: some View {
        Form {
            Section("Brain") {
                if let url = env.connection.brainURL {
                    LabeledContent("URL") {
                        Text(url.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Node ID") {
                        Text(env.connection.nodeId)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Status") {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(statusColor)
                    }
                } else {
                    Text("Not paired with a FERAL brain yet.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if env.connection.brainURL == nil {
                    Button {
                        showPairingSheet = true
                    } label: {
                        Label("Pair with a brain", systemImage: "qrcode.viewfinder")
                    }
                } else {
                    if env.brain.state.isConnected {
                        Button {
                            Task { await env.connection.disconnect() }
                        } label: {
                            Label("Disconnect", systemImage: "wifi.slash")
                        }
                    } else {
                        Button {
                            Task { await env.connection.connect() }
                        } label: {
                            Label("Connect", systemImage: "wifi")
                        }
                    }
                    Button(role: .destructive) {
                        Task { await env.connection.unpair() }
                    } label: {
                        Label("Unpair brain", systemImage: "xmark.circle")
                    }
                }
            }

            Section("About") {
                LabeledContent("Companion version", value: "0.3.0 (Phase 3)")
                LabeledContent("HUP version", value: FeralNodeSDKInfo.hupVersion)
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "?")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
    }

    private var statusText: String {
        switch env.connection.status {
        case .unpaired: return "unpaired"
        case .pairing(let m): return "pairing — \(m)"
        case .paired: return "paired (offline)"
        case .connecting: return "connecting…"
        case .connected: return "connected"
        case .reconnecting: return "reconnecting…"
        case .error(let m): return "error — \(m)"
        }
    }

    private var statusColor: Color {
        switch env.connection.status {
        case .connected: return .green
        case .error: return .red
        case .connecting, .reconnecting, .pairing: return .yellow
        case .paired: return .orange
        case .unpaired: return .gray
        }
    }
}
