import SwiftUI

@main
struct FeralCompanionApp: App {
    @StateObject private var environment = AppEnvironment.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    environment.handleDeepLink(url)
                }
                .onChange(of: scenePhase) { newPhase in
                    handleScenePhase(newPhase)
                }
        }
    }

    /// React to iOS lifecycle changes so we don't leak a half-dead
    /// WebSocket when the user backgrounds the app. The OS suspends
    /// `URLSessionWebSocketTask` after ~30s in background which leaves
    /// our brain-side socket in a weird "connected but writes fail"
    /// state — exactly the `Send failed with error "Socket is not
    /// connected"` log we observed on real iPhones. Cleanly tearing
    /// down on background and reconnecting on foreground is the
    /// canonical fix.
    ///
    /// Phase-1 truthfulness sweep adds explicit teardown of the BLE
    /// link (`JWBleSession`) and any in-flight phone-mic capture
    /// (`BrainClient.stopVoice`) so the OS never suspends the app
    /// with the radio + microphone still hot. Without this we ended
    /// up with three independent half-alive subsystems on background:
    /// the WS (already torn down), AVAudioEngine (engine.start was
    /// still active), and JWBle (BLE link still bonded).
    private func handleScenePhase(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            DebugLog.shared.info("scene: background — stopping voice/BLE + flushing chat history + closing WS")
            environment.brain.flushHistory()
            Task { @MainActor in
                // Order matters: stop voice first so the brain sees a
                // clean is_final chunk before the WS goes away. Then
                // close the WS. Disconnect the JWBle link last so any
                // queued `glasses_status: failed("…")` emit can ride
                // out on the open WS.
                await environment.brain.stopVoice()
                await environment.connection.disconnect()
                JWBleSession.shared.disconnect()
            }
        case .active:
            DebugLog.shared.info("scene: active — re-evaluating connection")
            // Reconnect if we have a saved pairing and aren't already up.
            Task { @MainActor in
                if case .paired = environment.connection.status {
                    await environment.connection.connect()
                }
            }
        case .inactive:
            // Transient state during transitions — no-op.
            break
        @unknown default:
            break
        }
    }
}
