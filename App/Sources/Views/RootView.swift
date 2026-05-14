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
                ContextView()
                    .navigationTitle("Context")
            }
            .tabItem { Label("Context", systemImage: "brain") }
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
            configureTabBarAppearance()
            if case .paired = env.connection.status {
                Task { await env.connection.connect() }
            }
            if case .unpaired = env.connection.status, !showPairingSheet {
            }
        }
        .preferredColorScheme(.dark)
        .tint(FeralTheme.accent)
    }

    private func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundColor = UIColor(FeralTheme.bgDeep.opacity(0.85))
        appearance.backgroundEffect = UIBlurEffect(style: .systemThinMaterialDark)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithDefaultBackground()
        navAppearance.backgroundColor = UIColor(FeralTheme.bgDeep.opacity(0.7))
        navAppearance.backgroundEffect = UIBlurEffect(style: .systemThinMaterialDark)
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor(FeralTheme.textPrimary)]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor(FeralTheme.textPrimary)]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
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
            Text(text).font(FeralTheme.fontMonoCaption)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(FeralTheme.surface0, in: Capsule())
        .overlay(Capsule().stroke(FeralTheme.hairline, lineWidth: 0.5))
    }

    private func badgeFor(_ status: ConnectionStore.Status) -> (Color, String) {
        switch status {
        case .unpaired:                  return (FeralTheme.textTertiary, "no brain")
        case .pairing:                   return (FeralTheme.stateWarn, "pairing…")
        case .paired:                    return (.orange, "paired · offline")
        case .connecting:                return (FeralTheme.stateWarn, "connecting…")
        case .connected:                 return (FeralTheme.stateLive, "online")
        case .reconnecting:             return (FeralTheme.stateWarn, "reconnecting…")
        case .error:                     return (FeralTheme.stateError, "error")
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppEnvironment.live())
}
