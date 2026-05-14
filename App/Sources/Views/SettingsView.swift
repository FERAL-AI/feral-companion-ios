import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    @Binding var showPairingSheet: Bool
    @State private var showLog = false
    @State private var probing = false
    @State private var lastProbeResult: String? = nil

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

            if let url = env.connection.brainURL {
                Section("Diagnostics") {
                    Button {
                        Task {
                            probing = true
                            let ok = await env.connection.testBrainReachability(url: url)
                            lastProbeResult = ok ? "Brain reachable ✓" : "Brain unreachable — see debug log"
                            probing = false
                        }
                    } label: {
                        if probing {
                            HStack { ProgressView(); Text("Probing brain…") }
                        } else {
                            Label("Test brain reachability", systemImage: "stethoscope")
                        }
                    }
                    if let result = lastProbeResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(result.contains("✓") ? Color.green : Color.red)
                    }
                }
            }

            Section("Debugging") {
                Button {
                    showLog = true
                } label: {
                    Label("Show debug log", systemImage: "doc.text.magnifyingglass")
                }
                Text("Captures pair attempts, brain probes, adapter activations, and errors. No need to attach Xcode.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("About") {
                LabeledContent("Companion version", value: "0.4.0 (Phase 3 + 6)")
                LabeledContent("HUP version", value: FeralNodeSDKInfo.hupVersion)
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "?")
            }
        }
        .scrollContentBackground(.hidden)
        .background(FeralTheme.bgDeep.ignoresSafeArea())
        .sheet(isPresented: $showLog) {
            DebugLogView()
        }
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
        case .connected: return FeralTheme.stateLive
        case .error: return FeralTheme.stateError
        case .connecting, .reconnecting, .pairing: return FeralTheme.stateWarn
        case .paired: return .orange
        case .unpaired: return FeralTheme.textTertiary
        }
    }
}
