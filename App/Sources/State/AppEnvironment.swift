import Foundation
import Combine

/// Top-level dependency container. Holds the canonical instances of
/// every long-lived service (brain client, adapter manager, stores).
/// Built once at app launch by ``FeralCompanionApp`` and injected
/// into the SwiftUI environment.
@MainActor
public final class AppEnvironment: ObservableObject {

    public let connection: ConnectionStore
    public let chat: ChatStore

    /// Convenience accessors so views don't reach into `connection.*`
    /// when they only need a single store.
    public var brain: BrainClient { connection.brainClient }
    public var devices: DeviceStore { connection.deviceStore }
    public var health: HealthStore { connection.healthStore }

    public init(connection: ConnectionStore, chat: ChatStore) {
        self.connection = connection
        self.chat = chat
        self.chat.bind(to: connection.brainClient)
    }

    /// Production wiring. Real `BrainClient`, real `DeviceStore`.
    public static func live() -> AppEnvironment {
        let conn = ConnectionStore()
        let chat = ChatStore()
        // Apple Health is activated by default — it always works on
        // any iPhone, and it's the universal "I have a Whoop / Garmin
        // / Apple Watch" path.
        conn.deviceStore.activate("apple_healthkit")
        return AppEnvironment(connection: conn, chat: chat)
    }

    // MARK: - Deep links

    /// Called from `App.onOpenURL` for `feral://pair?p=...` links.
    public func handleDeepLink(_ url: URL) {
        Task { @MainActor in
            guard let decoded = PairingClient.decode(url.absoluteString) else { return }
            await connection.applyPairing(decoded)
            // Auto-connect on a successful pairing — saves the user
            // a tap on the Pair screen.
            if case .paired = connection.status {
                await connection.connect()
            }
        }
    }
}
