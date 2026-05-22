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
    public let history: ChatHistoryStore

    /// Convenience accessors so views don't reach into `connection.*`
    /// when they only need a single store.
    public var brain: BrainClient { connection.brainClient }
    public var devices: DeviceStore { connection.deviceStore }
    public var health: HealthStore { connection.healthStore }

    /// Forwards `objectWillChange` from every nested ObservableObject
    /// up to AppEnvironment. SwiftUI views that only inject the
    /// environment object (the common case) get re-rendered when any
    /// nested store publishes — fixing the "have to close+reopen to
    /// see connected" bug surfaced during live iPhone testing.
    private var cancellables: Set<AnyCancellable> = []

    public init(
        connection: ConnectionStore,
        chat: ChatStore,
        history: ChatHistoryStore? = nil,
        bluetoothMonitor: BluetoothSystemMonitor? = nil
    ) {
        self.connection = connection
        self.chat = chat
        self.history = history ?? ChatHistoryStore()
        self.bluetoothMonitor = bluetoothMonitor ?? BluetoothSystemMonitor()
        self.chat.bind(to: connection.brainClient)
        // Wire chat history persistence into the BrainClient so every
        // append to `transcript` is debounced-saved to disk under the
        // current session id, and cold launches restore the most
        // recent session's transcript instead of an empty pane.
        connection.brainClient.bindHistory(self.history)
        wireForwarding()
    }

    private func wireForwarding() {
        // Forward every nested @Published-bearing store. We intentionally
        // include both ConnectionStore (status, brainURL) and BrainClient
        // (state, transcript, liveTranscript) so the toolbar badge updates
        // on either source of truth.
        connection.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        connection.brainClient.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        connection.deviceStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        connection.healthStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        chat.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        history.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Singleton Bluetooth system-state monitor. Held on the live
    /// environment so the `CBCentralManager` survives view-tree
    /// rebuilds and can outlive any single `DeviceStore` instance.
    public let bluetoothMonitor: BluetoothSystemMonitor

    /// Production wiring. Real `BrainClient`, real `DeviceStore`,
    /// real `CBCentralManager` observer + `JWBleSession` binding for
    /// truthful Bluetooth-row status (Phase 1).
    public static func live() -> AppEnvironment {
        let conn = ConnectionStore()
        let chat = ChatStore()
        let monitor = BluetoothSystemMonitor()
        monitor.bootstrap()
        // Single-writer rule for Bluetooth row status: the catalog
        // derives every BT row from the system power state and the
        // JWBle session phase, NOT from the synchronous activate path.
        // A BT row never reads `.active` unless both signals agree.
        conn.deviceStore.bindBluetoothMonitor(monitor)
        conn.deviceStore.bindJWBleSession(JWBleSession.shared)
        // Bind HealthStore to DeviceStore so adapters can write
        // readings into the local Vitals UI directly. Note: we do NOT
        // auto-activate HealthKit on first launch — the user taps
        // "Connect" on the Devices tab so the iOS permission prompt is
        // tied to a clear user action.
        conn.deviceStore.bind(healthStore: conn.healthStore)
        // Lane 11 (audit-r14) — bind BrainClient so HealthKitAdapter
        // can drive BrainHTTP.ingest(.healthKit, ...) for brain memory
        // writes alongside its realtime HUP device_event stream
        // (THESIS_SCENARIOS S2).
        conn.deviceStore.bind(brainClient: conn.brainClient)
        // Restore the user's previously-active adapter set so cold
        // launches send non-empty `node_register.capabilities` to the
        // brain. Otherwise every relaunch logs `caps: []` server-side.
        conn.deviceStore.restoreActiveCapabilities()
        // Safety net: if a brain is already paired but no adapters
        // were persisted (user paired in a build that predated
        // adapter-persistence), auto-activate Apple Health so the
        // brain sees real capabilities on the very next connect.
        // Without this fallback, already-paired users keep logging
        // `caps: []` server-side until they manually toggle the
        // Devices tab.
        if conn.brainURL != nil && conn.deviceStore.activeAdapters.isEmpty {
            DebugLog.shared.info("env: paired brain detected with empty caps — auto-activating apple_healthkit")
            conn.deviceStore.activate("apple_healthkit")
        }
        return AppEnvironment(connection: conn, chat: chat, bluetoothMonitor: monitor)
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
