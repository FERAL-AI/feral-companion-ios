import SwiftUI

/// Phase-1 root view. Just a "hello, the build works" placeholder so
/// we can verify Xcode signing + iPhone deploy before any real UI.
/// Phase 3 replaces this with the TabView shell (Chat / Health /
/// Pairing / Settings).
struct RootView: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("FERAL")
                .font(.system(size: 64, weight: .heavy, design: .monospaced))
                .tracking(4)
            Text("companion · phase 1 scaffold")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(statusLine)
                .font(.footnote.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var statusLine: String {
        "brain: \(env.connection.status) · adapters: \(env.devices.connectedAdapters.count)"
    }
}

#Preview {
    RootView()
        .environmentObject(AppEnvironment.live())
}
