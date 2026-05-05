import Foundation
import Combine

/// Top-level dependency container. Holds the canonical instances of
/// every long-lived service (brain client, adapter manager, stores).
/// Built once at app launch by ``FeralCompanionApp`` and injected
/// into the SwiftUI environment.
///
/// Construction is via ``live()`` for production and via the explicit
/// ``preview()`` factory for SwiftUI previews / unit tests so we never
/// accidentally instantiate the real WebSocket or AVFoundation paths
/// from a test.
@MainActor
public final class AppEnvironment: ObservableObject {

    // MARK: - Stores
    public let connection: ConnectionStore
    public let chat: ChatStore
    public let health: HealthStore
    public let devices: DeviceStore

    // MARK: - Construction

    public init(
        connection: ConnectionStore,
        chat: ChatStore,
        health: HealthStore,
        devices: DeviceStore
    ) {
        self.connection = connection
        self.chat = chat
        self.health = health
        self.devices = devices
    }

    /// Production wiring. Real `BrainClient`, real `DeviceManager`.
    public static func live() -> AppEnvironment {
        let connection = ConnectionStore()
        let chat = ChatStore()
        let health = HealthStore()
        let devices = DeviceStore()
        return AppEnvironment(
            connection: connection,
            chat: chat,
            health: health,
            devices: devices
        )
    }

    // MARK: - Deep links

    /// Called from `App.onOpenURL` for `feral://pair?p=...` links.
    /// Today this is a no-op until ``ConnectionStore.handleDeepLink``
    /// lands in Phase 3.
    public func handleDeepLink(_ url: URL) {
        // Phase 3 will route the URL into ConnectionStore.handlePairingPayload(url:)
    }
}
