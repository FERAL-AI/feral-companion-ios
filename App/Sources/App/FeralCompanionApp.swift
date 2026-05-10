import SwiftUI
import UIKit

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
    /// Phase-1 truthfulness sweep + Phase-1.5 hardening:
    ///
    /// * Synchronous-where-possible. `BrainClient.stopVoice` is the
    ///   only step that genuinely needs an `await` (it sends a final
    ///   audio chunk, which is async). The WS close and the
    ///   `JWBleSession.disconnect()` are MainActor methods we can call
    ///   immediately so the radio + mic are released before iOS
    ///   suspends us.
    /// * `UIBackgroundTaskIdentifier` extends the runtime up to ~30s
    ///   so iOS doesn't kill us mid-`stopVoice`. Always paired with
    ///   `endBackgroundTask` so we never leak the assertion.
    /// * Order is FIXED: voice → WS bye → BLE. The brain sees a
    ///   clean `is_final` audio chunk; queued `glasses_status:
    ///   disconnected` emits ride out on the open WS; the BLE link
    ///   tears down last.
    private func handleScenePhase(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            DebugLog.shared.info(
                "scene: background — stopping voice/BLE + flushing chat history + closing WS"
            )
            environment.brain.flushHistory()
            // Take a background-task assertion so iOS gives us up to
            // ~30s to finish the asynchronous voice teardown. Always
            // ended in the trailing `defer` analogue at the bottom of
            // the Task to guarantee no leak.
            let app = UIApplication.shared
            var bgTaskID: UIBackgroundTaskIdentifier = .invalid
            bgTaskID = app.beginBackgroundTask(withName: "feral.scene.background.teardown") {
                // Expiration handler: iOS gave us less time than we
                // asked for. End the assertion so we don't get
                // killed for hanging onto it.
                if bgTaskID != .invalid {
                    app.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
            Task { @MainActor in
                await environment.brain.stopVoice()
                // WS close and JWBle disconnect are MainActor sync
                // methods; no await needed and the brain receives
                // the queued `glasses_status: disconnected` emit on
                // the still-open socket because stopVoice already
                // returned.
                await environment.connection.disconnect()
                JWBleSession.shared.disconnect()
                if bgTaskID != .invalid {
                    app.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
        case .active:
            DebugLog.shared.info("scene: active — re-evaluating connection")
            // Reconnect if we have a saved pairing and aren't already
            // up. Phase 1.5: also kick the auto-reconnect path on the
            // JWBle session so the previously-paired Theora glasses
            // come back without the user re-opening the BLE scan
            // modal. Guarded by ``didKickReconnectThisActivation`` to
            // avoid spamming reconnect on rapid `.active` transitions
            // (Control Center / notification banner taps).
            Task { @MainActor in
                if didKickReconnectThisActivation { return }
                didKickReconnectThisActivation = true
                if case .paired = environment.connection.status {
                    await environment.connection.connect()
                }
                // Only attempt auto-reconnect when the user has
                // previously paired a JWBle peripheral; the session
                // itself bails if the persisted UUID is missing.
                JWBleSession.shared.attemptAutoReconnect()
            }
        case .inactive:
            // Transient state during transitions — reset the
            // reconnect-kick flag so the next genuine .active
            // transition reattempts.
            didKickReconnectThisActivation = false
        @unknown default:
            break
        }
    }
}

// `didKickReconnectThisActivation` lives on the App struct as
// a private static so the Task closure above doesn't capture self
// (App is a @main struct; capturing self forces it to be a class).
// Using a file-private mutable is a deliberate tradeoff — the
// flag's only purpose is debouncing rapid `.active` transitions on
// the SAME process, so cross-launch state is irrelevant.
private var didKickReconnectThisActivation: Bool = false
