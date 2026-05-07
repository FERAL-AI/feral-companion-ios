import Foundation
import SwiftUI
import Combine
import CoreBluetooth

/// Catalog of every adapter the app knows about. Each entry can be
/// in one of three runtime states: not-tried, active (transport
/// confirmed), or failed.
///
/// **Truthfulness contract** (Phase 1):
///
/// * The `intent` set is what the **user has activated**. Persisted
///   across launches as `feral.activeCapabilities`.
/// * Each `Entry.status` is the **runtime view**. For Bluetooth caps
///   it is derived from `JWBleSession.phase` and the iOS Bluetooth
///   power state — the store never flips a BT row to `.active` from
///   the activation path alone.
/// * For HealthKit / cloud caps, the status is driven by the adapter
///   preflight (HealthKit permission grant, OAuth token) but still
///   gated through `updateStatus` so a single writer owns transitions.
@MainActor
public final class DeviceStore: ObservableObject {

    public struct Entry: Identifiable, Equatable {
        public let id: String                // capability string
        public let displayName: String
        public let summary: String
        public let category: Category
        public var status: Status

        public enum Category: String, CaseIterable {
            case iphoneBuiltin = "iPhone built-ins"
            case bluetooth = "Bluetooth devices"
            case healthKitMediated = "Sync from Apple Health"

            public var icon: String {
                switch self {
                case .iphoneBuiltin: return "iphone"
                case .bluetooth: return "antenna.radiowaves.left.and.right"
                case .healthKitMediated: return "heart.text.square"
                }
            }
        }

        public enum Status: Equatable {
            case available
            case active
            case connecting
            case failed(reason: String)
            case unsupported(reason: String)
        }
    }

    @Published public private(set) var entries: [Entry] = []
    public private(set) var activeAdapters: [VendorAdapter] = []

    /// Capabilities the user has explicitly turned on. Persisted to
    /// UserDefaults so a cold launch sends a non-empty
    /// `node_register.capabilities` to the brain.
    public private(set) var intent: Set<String> = []

    /// Last-known iOS Bluetooth power state. Set via the bound
    /// `BluetoothSystemMonitor`; defaults to `false` so a Bluetooth
    /// row never reads `.active` until `CBCentralManager` has
    /// explicitly confirmed `.poweredOn` (Phase-1.5 strict cold
    /// launch). Non-BT capabilities are unaffected by this flag.
    public private(set) var bluetoothPoweredOn: Bool = false

    /// Last-known `CBManagerState`. Held alongside
    /// ``bluetoothPoweredOn`` so the row can render distinct
    /// `failed` reasons for `.unknown` / `.resetting` /
    /// `.unauthorized` / `.poweredOff`.
    public private(set) var bluetoothState: CBManagerState = .unknown

    /// Last-known `JWBleSession.phase`. Set via the bound session;
    /// defaults to `.idle` since no link exists at construction.
    public private(set) var jwBlePhase: JWBleSession.Phase = .idle

    /// Lazily-initialized adapter instances keyed by capability.
    private var adapterByCapability: [String: VendorAdapter] = [:]

    /// Set after `bind(healthStore:)`. Adapters that surface readings
    /// to the local Vitals UI receive a reference so the tab populates
    /// without waiting for the brain round-trip.
    private weak var healthStore: HealthStore?

    private let defaults: UserDefaults
    private static let activeCapabilitiesKey = "feral.activeCapabilities"

    /// Capability ids that live behind the JWBle BLE link. Phase 1
    /// only ships `jw_health_glasses`; future Theora-platform caps
    /// (camera, mic, display) plug into the same derivation.
    private static let jwBleCapabilities: Set<String> = ["jw_health_glasses"]

    private var bluetoothMonitor: BluetoothSystemMonitor?
    private var jwBleSession: JWBleSession?
    private var cancellables: Set<AnyCancellable> = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seedCatalog()
    }

    public func bind(healthStore: HealthStore) {
        self.healthStore = healthStore
    }

    /// Subscribe to the iOS Bluetooth power state. The monitor must
    /// already have called `bootstrap()` (or be a test seam). Triggers
    /// an immediate derivation pass with the current state so the
    /// catalog reflects reality on first paint.
    public func bindBluetoothMonitor(_ monitor: BluetoothSystemMonitor) {
        self.bluetoothMonitor = monitor
        monitor.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                self?._applyBluetoothState(newState)
            }
            .store(in: &cancellables)
    }

    /// Subscribe to the JWBle session phase. Must be called after the
    /// session is set up by `BLEScanView` / the SDK callbacks; triggers
    /// an immediate derivation pass with the current phase.
    public func bindJWBleSession(_ session: JWBleSession) {
        self.jwBleSession = session
        session.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] newPhase in
                self?._applyJWBlePhase(newPhase)
            }
            .store(in: &cancellables)
    }

    // MARK: - Persistence

    /// Restore intent from UserDefaults so a cold launch sends a
    /// non-empty `node_register.capabilities` to the brain. Without
    /// this, every relaunch logs `caps: []` server-side until the
    /// user manually re-toggles each adapter in the Devices tab.
    ///
    /// **Truthfulness contract**: restoring intent does NOT flip any
    /// BT row to `.active`. Status is derived; the row only reads
    /// `.active` once the JWBle session reports `.ready` and the
    /// system Bluetooth radio is powered on.
    public func restoreActiveCapabilities() {
        guard let saved = defaults.array(forKey: Self.activeCapabilitiesKey) as? [String] else { return }
        for cap in saved {
            // Skip capabilities the catalog doesn't know about (e.g.
            // schema drift between app versions).
            guard entries.contains(where: { $0.id == cap }) else { continue }
            activate(cap)
        }
    }

    private func persist() {
        let caps = activeAdapters.map(\.capability)
        defaults.set(caps, forKey: Self.activeCapabilitiesKey)
    }

    public func deactivateAll() {
        for cap in activeAdapters.map(\.capability) {
            deactivate(cap)
        }
        defaults.removeObject(forKey: Self.activeCapabilitiesKey)
    }

    // MARK: - Catalog

    private func seedCatalog() {
        entries = [
            Entry(
                id: "apple_healthkit",
                displayName: "Apple Health",
                summary: "Reads HR, SpO2, steps, sleep from any wearable that syncs to Apple Health (Apple Watch, Whoop, Garmin, Oura, Fitbit, Polar, …)",
                category: .healthKitMediated,
                status: .available
            ),
            Entry(
                id: "iphone_camera",
                displayName: "iPhone camera + microphone",
                summary: "Phone-as-glasses fallback. Streams camera frames + voice when no external glasses are paired.",
                category: .iphoneBuiltin,
                status: .available
            ),
            Entry(
                id: "jw_health_glasses",
                displayName: "Theora Glasses",
                summary: "Theora prototype glasses (W300 platform). HR, SpO2, body temp, UV, steps, vibration over BLE.",
                category: .bluetooth,
                status: .available
            ),
            Entry(
                id: "veepoo_wristband",
                displayName: "Veepoo Wristband",
                summary: "First-party FERAL wristband. HR, SpO2, body temp, ECG over BLE.",
                category: .bluetooth,
                status: .unsupported(reason: "Vendor frameworks not yet linked into this build")
            ),
            Entry(
                id: "w610_glasses",
                displayName: "W610 Open Glasses (QCSDK)",
                summary: "Open-source Meta-Ray-Ban-style glasses. Camera, audio, IMU.",
                category: .bluetooth,
                status: .unsupported(reason: "Vendor frameworks not yet linked into this build")
            ),
            Entry(
                id: "generic_ble_hr",
                displayName: "Standard BLE Heart Rate (any chest strap / monitor)",
                summary: "Auto-discover any BLE device implementing the standard Heart Rate Service (0x2A37). Polar, Wahoo, generic chest straps.",
                category: .bluetooth,
                status: .unsupported(reason: "Generic GATT adapter is post-demo (planned)")
            ),
        ]
    }

    // MARK: - Activation

    /// Record user intent for the given capability and run any adapter
    /// preflight (e.g. HealthKit permission prompt). For Bluetooth
    /// capabilities the row's runtime status is then derived from the
    /// JWBle session phase + the iOS Bluetooth power state — this
    /// method does **not** unconditionally flip a BT row to `.active`.
    public func activate(_ capability: String) {
        guard let adapter = makeAdapter(for: capability) else {
            updateStatus(capability, to: .unsupported(reason: "Adapter not implemented in this build"))
            return
        }
        intent.insert(capability)
        adapterByCapability[capability] = adapter
        if !activeAdapters.contains(where: { $0.capability == capability }) {
            activeAdapters.append(adapter)
        }

        if isBluetoothCapability(capability) {
            // Bluetooth rows are owned by the derivation pass below.
            // Run it now so the row reflects the current transport
            // state immediately (e.g. picks up a `.ready` JWBle phase
            // that arrived before activation).
            _recomputeBluetoothStatus(for: capability)
        } else {
            updateStatus(capability, to: .active)
        }
        persist()

        // Adapter-specific preflight runs immediately on the main actor.
        // For HealthKit this triggers the iOS permission sheet AND
        // primes the Vitals UI with a one-shot read, so the user sees
        // something happen even before they pair a brain.
        if let hk = adapter as? HealthKitAdapter {
            if let store = healthStore { hk.setHealthStore(store) }
            Task { [weak self] in
                do {
                    try await hk.requestPermissionsAndPrime()
                } catch {
                    await MainActor.run {
                        self?.updateStatus(capability, to: .failed(reason: error.localizedDescription))
                    }
                }
            }
        }
    }

    /// Drop user intent for the capability and remove its adapter. For
    /// Bluetooth capabilities the JWBle session is also disconnected
    /// so the underlying BLE link is torn down — no orphan radio
    /// activity after a Devices-tab "Disconnect".
    public func deactivate(_ capability: String) {
        intent.remove(capability)
        adapterByCapability.removeValue(forKey: capability)
        activeAdapters.removeAll { $0.capability == capability }

        if isBluetoothCapability(capability) {
            jwBleSession?.disconnect()
            // No JWBle phase to consult yet (we may have called
            // disconnect synchronously); fall back to .available so
            // the row offers Connect again.
            updateStatus(capability, to: .available)
        } else {
            updateStatus(capability, to: .available)
        }
        persist()
    }

    private func makeAdapter(for capability: String) -> VendorAdapter? {
        switch capability {
        case "apple_healthkit":
            return HealthKitAdapter()
        case "iphone_camera":
            return CameraPermissionAdapter()
        case "jw_health_glasses":
            // Real wired adapter — Vendor frameworks must be present
            // at Vendor/JWBle.framework. The companion app target
            // links + embeds them via project.yml.
            return JWBleAdapterWired()
        case "veepoo_wristband":
            return VeepooAdapter()
        case "w610_glasses":
            return QCSDKAdapter()
        default:
            return nil
        }
    }

    private func updateStatus(_ capability: String, to status: Entry.Status) {
        guard let idx = entries.firstIndex(where: { $0.id == capability }) else { return }
        if entries[idx].status == status { return }
        entries[idx].status = status
    }

    // MARK: - Derivation (single writer for Bluetooth rows)

    private func isBluetoothCapability(_ capability: String) -> Bool {
        Self.jwBleCapabilities.contains(capability)
    }

    /// Recompute the status for every Bluetooth row that the user has
    /// expressed intent for. Cold-launch + BT off + restored intent
    /// must end with each row showing `.failed("Bluetooth is off…")`,
    /// not `.active`. Cold-launch + BT on + JWBle `.idle` shows
    /// `.available` so the Connect button re-appears.
    private func _recomputeBluetoothStatus() {
        for entry in entries where entry.category == .bluetooth {
            if case .unsupported = entry.status { continue }
            _recomputeBluetoothStatus(for: entry.id)
        }
    }

    private func _recomputeBluetoothStatus(for capability: String) {
        guard isBluetoothCapability(capability) else { return }
        // System BT off / unknown / resetting / unauthorized always
        // wins — even if JWBleSession.phase still reads `.ready`
        // because the link hasn't dropped yet, we know the radio is
        // not in a state where a heartbeat can succeed. Phase-1.5
        // strict cold-launch contract: the row only reads `.active`
        // when `CBCentralManager` has explicitly confirmed
        // `.poweredOn`.
        if !bluetoothPoweredOn {
            let reason: String
            switch bluetoothState {
            case .poweredOff:
                reason = "Bluetooth is off — turn it on in Settings"
            case .unauthorized:
                reason = "FERAL needs Bluetooth permission — open Settings → FERAL → Bluetooth"
            case .unsupported:
                reason = "This device does not support Bluetooth Low Energy"
            case .resetting:
                reason = "Bluetooth is resetting — wait a moment and retry"
            case .unknown:
                reason = "Bluetooth state unknown — waiting for system"
            case .poweredOn:
                // Should never happen because !bluetoothPoweredOn;
                // included for exhaustiveness.
                reason = "Bluetooth state inconsistent"
            @unknown default:
                reason = "Bluetooth state unknown — waiting for system"
            }
            updateStatus(capability, to: .failed(reason: reason))
            return
        }

        let userWantsActive = intent.contains(capability)
        switch jwBlePhase {
        case .ready:
            updateStatus(capability, to: .active)
        case .connecting:
            updateStatus(capability, to: .connecting)
        case .failed(let reason):
            // Surface the JWBle SDK's own reason text — the user gets
            // "Bond failed — device may be paired to another phone"
            // instead of a generic failure dot.
            updateStatus(capability, to: .failed(reason: reason))
        case .scanning, .idle:
            // No active link. If the user wanted this row active, show
            // `.available` so the Connect button re-appears (truthful:
            // we are not connected). If they didn't, also `.available`.
            _ = userWantsActive  // intent affects deactivate semantics, not status here
            updateStatus(capability, to: .available)
        }
    }

    // MARK: - State subscriptions (test seams)

    /// Apply a Bluetooth power state. Public for tests; production
    /// code subscribes via `bindBluetoothMonitor`. Treats every
    /// state other than `.poweredOn` as "BT row cannot be active"
    /// — `.unknown` and `.resetting` are deliberately conservative
    /// so a slow CoreBluetooth bring-up never lets a row briefly
    /// claim `.active`.
    public func _applyBluetoothState(_ state: CBManagerState) {
        self.bluetoothState = state
        self.bluetoothPoweredOn = (state == .poweredOn)
        _recomputeBluetoothStatus()
    }

    /// Apply a JWBle session phase. Public for tests; production code
    /// subscribes via `bindJWBleSession`.
    public func _applyJWBlePhase(_ phase: JWBleSession.Phase) {
        jwBlePhase = phase
        _recomputeBluetoothStatus()
    }
}
