import SwiftUI

/// Root tab shell. Four tabs — Chat, Health, Devices, Settings.
/// The Chat tab is the front door: voice + text loop with the brain.
struct RootView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var selectedTab = 0
    @State private var showPairingSheet = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ChatView()
                    .navigationTitle("FERAL")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            ConnectionStatusBadge()
                        }
                    }
            }
            .tabItem { Label("Chat", systemImage: "waveform") }
            .tag(0)

            NavigationStack {
                HealthView()
                    .navigationTitle("Vitals")
            }
            .tabItem { Label("Vitals", systemImage: "heart.fill") }
            .tag(1)

            NavigationStack {
                DevicesView()
                    .navigationTitle("Devices")
            }
            .tabItem { Label("Devices", systemImage: "link") }
            .tag(2)

            NavigationStack {
                SettingsView(showPairingSheet: $showPairingSheet)
                    .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(3)
        }
        .sheet(isPresented: $showPairingSheet) {
            PairingView(isPresented: $showPairingSheet)
                .environmentObject(env)
        }
        .onAppear {
            // If we have a saved pairing but aren't connected, kick
            // off a connection automatically.
            if case .paired = env.connection.status {
                Task { await env.connection.connect() }
            }
            // If we have no pairing at all, offer the sheet.
            if case .unpaired = env.connection.status, !showPairingSheet {
                // Don't auto-present on first run; let the user reach
                // Settings or tap the badge in Chat to start pairing.
            }
        }
        .preferredColorScheme(.dark)
        .tint(.green)
    }
}

/// Compact connection status pill rendered in the Chat toolbar.
struct ConnectionStatusBadge: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        let status = env.connection.status
        let (color, text) = badgeFor(status)
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption.monospaced())
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.white.opacity(0.05), in: Capsule())
    }

    private func badgeFor(_ status: ConnectionStore.Status) -> (Color, String) {
        switch status {
        case .unpaired:                  return (.gray, "no brain")
        case .pairing:                   return (.yellow, "pairing…")
        case .paired:                    return (.orange, "paired · offline")
        case .connecting:                return (.yellow, "connecting…")
        case .connected:                 return (.green, "online")
        case .reconnecting:              return (.yellow, "reconnecting…")
        case .error:                     return (.red, "error")
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppEnvironment.live())
}
