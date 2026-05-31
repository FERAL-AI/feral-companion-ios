import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

/// SDK-shipped generic BLE-peripheral discovery adapter.
///
/// Conforms to ``VendorAdapter`` so any FeralNode-hosting app can
/// register it with one line:
///
/// ```swift
/// let scanner = BLEPeripheralScannerAdapter()
/// await node.register(adapter: scanner)
/// ```
///
/// On ``attach(to:)`` the adapter spins up a ``CBCentralManager`` and,
/// for each non-FERAL peripheral the iPhone observes, emits a HUP
/// v1.3.0 ``device_announce`` envelope (HUP_SPEC §5.4.4) via
/// ``FeralNode.sendDeviceAnnounce(...)``. The brain's hardware mesh
/// upserts a knowledge-graph entity (``category=device``) so
/// orchestrator queries like "what BLE devices are around the phone
/// right now?" land on real memory.
///
/// ## Design contract — observation only
///
/// The scanner **never** initiates a GATT connection, **never**
/// requests pairing, and **never** subscribes to notifications. It
/// only forwards what `CBCentralManagerDelegate.didDiscover` reports.
/// Any GATT interaction belongs to a vendor-specific adapter
/// (``JWBleAdapter``, ``QCSDKAdapter``, ``VeepooAdapter``).
///
/// ## Throttle + lifecycle
///
/// * **Dedupe**: each peripheral UUID emits at most one announce per
///   ``reannounceInterval`` (default 60 s). RSSI jitter or rapid
///   re-advertisements don't churn the brain's mesh.
/// * **Re-announce**: while a peripheral is still being seen, the
///   scanner re-emits every ``reannounceInterval`` so the brain's
///   ``last_seen`` field stays fresh.
/// * **Lost marker**: if a peripheral hasn't been observed for
///   ``lostThresholdInterval`` (default 120 s), the scanner emits a
///   final ``device_announce`` with ``metadata.lost = true``. There is
///   no separate ``device_lost`` envelope on the wire today
///   (HUP_SPEC v1.3.0); the brain detects loss via the boolean flag.
/// * **Self-filter**: peripherals that advertise any service UUID in
///   ``ferralServiceUUIDs`` are silently skipped so the scanner
///   doesn't double-announce against ``JWBleAdapter`` /
///   ``QCSDKAdapter`` / ``VeepooAdapter`` peers on the same node.
///
/// ## Permissions
///
/// Hosts MUST add ``NSBluetoothAlwaysUsageDescription`` to their
/// `Info.plist`. Optional: ``UIBackgroundModes`` -> ``bluetooth-central``
/// for scans that should survive a quick app backgrounding. See
/// ``FeralCompanion``'s `Info.plist` for the canonical wording.
///
/// ## Testing seam
///
/// CoreBluetooth is hard to mock — `CBCentralManager` has private
/// init paths. Instead of seaming the OS class, this adapter exposes
/// pure-Swift handlers (``_test_handleDiscovery(...)`` and
/// ``_test_evaluateLostPeripherals()``) that drive the same dedupe /
/// re-announce / lost-marker logic the real delegate calls into. Unit
/// tests construct the adapter, attach a mocked ``FeralNode``-style
/// announcer, and verify the announce shape directly. See
/// ``BLEPeripheralScannerAdapterTests``.
#if canImport(CoreBluetooth)
@MainActor
public final class BLEPeripheralScannerAdapter: NSObject, VendorAdapter, CBCentralManagerDelegate {

    public let capability: String = "ble_peripheral_scanner"

    /// Minimum wall-clock seconds between successive ``device_announce``
    /// emissions for the same peripheral UUID. 60 s by default — keeps
    /// the brain's mesh from churning on RSSI jitter while still
    /// refreshing ``last_seen`` quickly enough that a peripheral that
    /// genuinely went silent is detectable.
    public let reannounceInterval: TimeInterval

    /// After this many seconds without a discovery callback for a
    /// peripheral, the scanner emits a final ``device_announce`` with
    /// ``metadata.lost = true``. 120 s by default — twice the
    /// re-announce interval, so a single missed advertising window
    /// doesn't trigger a false-positive loss event.
    public let lostThresholdInterval: TimeInterval

    /// Cadence (seconds) at which the scanner sweeps its peripheral
    /// table looking for entries whose ``lastSeenAt`` exceeds
    /// ``lostThresholdInterval``. Default 30 s. Lower = more sensitive
    /// loss detection at the cost of more wakeups.
    public let lostSweepInterval: TimeInterval

    /// Service UUIDs whose advertising peripherals should be ignored —
    /// FERAL's own glasses + wristband adapters publish these and the
    /// generic scanner shouldn't double-announce them. Empty by
    /// default; hosts inject their vendor SDK's known service UUIDs.
    public let ferralServiceUUIDs: Set<String>

    /// Test-only observer fired from ``emitAnnounce`` BEFORE the
    /// asynchronous WebSocket send is dispatched. Unit tests assign
    /// this so they can verify which peripherals were announced and
    /// whether the lost flag was set, without needing a connected
    /// ``FeralNode`` (the WS send fails with ``notConnected`` and is
    /// swallowed — that's fine for production but useless for
    /// assertions). Production callers leave this as ``nil``.
    public var _test_announceObserver: ((BLEPeripheralAnnounce) -> Void)?

    private weak var attachedNode: FeralNode?
    private var central: CBCentralManager?
    private var lostSweepTimer: Timer?

    /// Per-peripheral state, keyed by ``CBPeripheral.identifier.uuidString``.
    /// We keep enough info to re-announce when the dedupe window closes
    /// and to emit a final lost announce — the scanner has to remember
    /// the peripheral metadata even after the OS stops reporting it.
    private struct PeripheralState {
        var name: String
        var manufacturer: String
        var rssi: Int
        var serviceUUIDs: [String]
        /// Wall-clock timestamp of the most recent discovery callback
        /// for this peripheral. Compared against ``lostThresholdInterval``
        /// during ``_test_evaluateLostPeripherals``.
        var lastSeenAt: Date
        /// Wall-clock timestamp of the most recent
        /// ``device_announce`` we emitted for this peripheral. Compared
        /// against ``reannounceInterval`` to throttle re-emits.
        var lastAnnouncedAt: Date?
        /// True after we've emitted a lost-marker announce — keeps the
        /// scanner from emitting it twice if the peripheral stays
        /// quiet across multiple sweep ticks.
        var lostMarkerEmitted: Bool
    }
    private var peripherals: [String: PeripheralState] = [:]

    public init(
        reannounceInterval: TimeInterval = 60.0,
        lostThresholdInterval: TimeInterval = 120.0,
        lostSweepInterval: TimeInterval = 30.0,
        ferralServiceUUIDs: Set<String> = []
    ) {
        precondition(reannounceInterval > 0, "reannounceInterval must be > 0")
        precondition(lostThresholdInterval > reannounceInterval,
                     "lostThresholdInterval must exceed reannounceInterval " +
                     "or every dedupe window will look like a loss event")
        precondition(lostSweepInterval > 0, "lostSweepInterval must be > 0")
        self.reannounceInterval = reannounceInterval
        self.lostThresholdInterval = lostThresholdInterval
        self.lostSweepInterval = lostSweepInterval
        self.ferralServiceUUIDs = ferralServiceUUIDs
        super.init()
    }

    // MARK: - VendorAdapter

    public func attach(to node: FeralNode) async throws {
        self.attachedNode = node
        if central == nil {
            central = CBCentralManager(
                delegate: self,
                queue: nil,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        }
        startLostSweepTimer()
        // Don't start the scan here — wait for ``centralManagerDidUpdateState``
        // to confirm ``.poweredOn``. Calling ``scanForPeripherals`` while
        // the manager is still ``.unknown`` is a no-op on iOS but logs a
        // warning to the console; we honour the API contract.
    }

    public func detach() async {
        central?.stopScan()
        lostSweepTimer?.invalidate()
        lostSweepTimer = nil
        attachedNode = nil
        // Don't clear ``peripherals`` — a re-attach should keep the
        // last-seen state so a transient disconnect doesn't trigger a
        // burst of duplicate announces.
    }

    public func canHandleAction(named name: String) async -> Bool {
        // Observation-only adapter — no inbound action_request shape
        // is dispatched here. Returning false keeps the brain's
        // capability registry from routing arbitrary actions through
        // the scanner.
        return false
    }

    public func handleAction(frame: HUPFrame, node: FeralNode) async {
        // No-op (see canHandleAction).
    }

    // MARK: - CBCentralManagerDelegate
    //
    // CoreBluetooth callbacks arrive on the manager's dispatch queue
    // (we passed ``nil`` so it uses the main queue). The closures
    // hop back onto the actor-isolated handlers below to keep all
    // peripheral-state mutation on the main actor.

    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let powered = central.state == .poweredOn
        Task { @MainActor [weak self] in
            self?.handleStateChange(poweredOn: powered)
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Capture every value we need from ``advertisementData`` BEFORE
        // hopping back onto the main actor — the dictionary is
        // delivered on Core Bluetooth's queue and isn't Sendable across
        // actor boundaries.
        let deviceId = peripheral.identifier.uuidString
        let name =
            advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name
            ?? ""
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let manufacturer = decodeManufacturer(data: manufacturerData)
        let serviceUUIDs =
            (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
                .map { $0.uuidString } ?? []
        let rssi = RSSI.intValue

        Task { @MainActor [weak self] in
            self?._test_handleDiscovery(
                deviceId: deviceId,
                name: name,
                manufacturer: manufacturer,
                rssi: rssi,
                serviceUUIDs: serviceUUIDs,
                now: Date()
            )
        }
    }

    private func handleStateChange(poweredOn: Bool) {
        guard poweredOn else {
            central?.stopScan()
            return
        }
        guard let central = central, !central.isScanning else { return }
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func startLostSweepTimer() {
        lostSweepTimer?.invalidate()
        lostSweepTimer = Timer.scheduledTimer(
            withTimeInterval: lostSweepInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?._test_evaluateLostPeripherals(now: Date())
            }
        }
    }

    // MARK: - Pure-Swift core (test seams)
    //
    // The two methods below carry every announce / lost / dedupe
    // decision the adapter makes. They're called from the
    // CoreBluetooth delegate callbacks above (production) AND from
    // ``BLEPeripheralScannerAdapterTests`` (unit tests). Drive them
    // directly to verify behaviour without conjuring a CBCentralManager.
    // ``now`` is injected so tests can fast-forward time deterministically.

    /// Test seam — called by ``didDiscover`` (production) AND by
    /// unit tests. Applies the FERAL-self-filter, the dedupe window,
    /// and emits a ``device_announce`` (or schedules a deferred one)
    /// via the attached node.
    @discardableResult
    public func _test_handleDiscovery(
        deviceId: String,
        name: String,
        manufacturer: String,
        rssi: Int,
        serviceUUIDs: [String],
        now: Date
    ) -> Bool {
        // FERAL-self-filter: any advertised service UUID matching the
        // host's vendor-adapter set => skip. This prevents the
        // generic scanner from double-announcing a Theora-glasses
        // peripheral that JWBleAdapter is already managing.
        let normalised = Set(serviceUUIDs.map { $0.uppercased() })
        let ferralUpper = Set(ferralServiceUUIDs.map { $0.uppercased() })
        if !normalised.isDisjoint(with: ferralUpper) {
            return false
        }

        var state = peripherals[deviceId] ?? PeripheralState(
            name: name,
            manufacturer: manufacturer,
            rssi: rssi,
            serviceUUIDs: serviceUUIDs,
            lastSeenAt: now,
            lastAnnouncedAt: nil,
            lostMarkerEmitted: false
        )
        state.name = name.isEmpty ? state.name : name
        state.manufacturer = manufacturer.isEmpty ? state.manufacturer : manufacturer
        state.rssi = rssi
        if !serviceUUIDs.isEmpty { state.serviceUUIDs = serviceUUIDs }
        state.lastSeenAt = now
        // Re-discovery resets the lost flag — if the peripheral comes
        // back into range we want to announce it as "found" again
        // rather than stay stuck on the prior lost marker.
        state.lostMarkerEmitted = false

        let dueForAnnounce: Bool
        if let last = state.lastAnnouncedAt {
            dueForAnnounce = now.timeIntervalSince(last) >= reannounceInterval
        } else {
            dueForAnnounce = true
        }
        if dueForAnnounce {
            state.lastAnnouncedAt = now
            peripherals[deviceId] = state
            emitAnnounce(deviceId: deviceId, state: state, lost: false)
            return true
        }
        peripherals[deviceId] = state
        return false
    }

    /// Test seam — called by ``lostSweepTimer`` (production) AND by
    /// unit tests. Walks the peripheral table and emits a final
    /// ``device_announce`` with ``metadata.lost = true`` for each
    /// peripheral whose ``lastSeenAt`` is older than
    /// ``lostThresholdInterval``. Idempotent — once a lost marker is
    /// emitted the entry is flagged so the next sweep is a no-op.
    public func _test_evaluateLostPeripherals(now: Date) {
        for (deviceId, var state) in peripherals {
            guard !state.lostMarkerEmitted else { continue }
            let elapsed = now.timeIntervalSince(state.lastSeenAt)
            guard elapsed >= lostThresholdInterval else { continue }
            state.lostMarkerEmitted = true
            peripherals[deviceId] = state
            emitAnnounce(deviceId: deviceId, state: state, lost: true)
        }
    }

    private func emitAnnounce(deviceId: String, state: PeripheralState, lost: Bool) {
        var metadata: [String: AnyCodable] = [:]
        if lost {
            metadata["lost"] = .bool(true)
            // Forward the wall-clock loss time so the brain mesh's
            // entity record can show "last seen: ~X s ago" without
            // having to interpolate from `last_seen`.
            metadata["lost_at"] = .double(Date().timeIntervalSince1970)
        }
        let name = state.name
        let manufacturer = state.manufacturer
        let services = state.serviceUUIDs
        let rssi = state.rssi
        let metadataSnapshot = metadata
        // Fire the test observer first — synchronously, on the main
        // actor — so unit tests can assert against the announce
        // regardless of whether the FeralNode actually has a connected
        // WebSocket. Production builds leave the observer nil so this
        // is a single nil-check then a guarded async send.
        _test_announceObserver?(BLEPeripheralAnnounce(
            deviceId: deviceId,
            name: name,
            manufacturer: manufacturer,
            rssi: rssi,
            advertisedServices: services,
            lost: lost
        ))
        guard let node = attachedNode else { return }
        Task {
            do {
                try await node.sendDeviceAnnounce(
                    deviceId: deviceId,
                    deviceKind: "bluetooth_le",
                    name: name,
                    manufacturer: manufacturer,
                    rssiDbm: rssi,
                    advertisedServices: services,
                    metadata: metadataSnapshot
                )
            } catch {
                // Best-effort — the brain's mesh tolerates dropped
                // announces (the next discovery callback will retry).
                NSLog(
                    "BLEPeripheralScannerAdapter: device_announce emit failed for %@: %@",
                    deviceId, error.localizedDescription
                )
            }
        }
    }
}

/// Snapshot of a single ``device_announce`` emission, used by the
/// adapter's ``_test_announceObserver`` test seam. Captures the values
/// the adapter forwards to ``FeralNode.sendDeviceAnnounce(...)`` so
/// unit tests can verify the wire shape without standing up a real
/// WebSocket.
public struct BLEPeripheralAnnounce: Equatable, Sendable {
    public let deviceId: String
    public let name: String
    public let manufacturer: String
    public let rssi: Int
    public let advertisedServices: [String]
    public let lost: Bool

    public init(
        deviceId: String,
        name: String,
        manufacturer: String,
        rssi: Int,
        advertisedServices: [String],
        lost: Bool
    ) {
        self.deviceId = deviceId
        self.name = name
        self.manufacturer = manufacturer
        self.rssi = rssi
        self.advertisedServices = advertisedServices
        self.lost = lost
    }
}

// MARK: - Manufacturer-data decoder
//
// BLE manufacturer data leads with a 16-bit little-endian "Company
// Identifier" from the Bluetooth SIG's assigned-numbers catalogue.
// We map the operator-visible names FERAL cares about (Apple,
// Samsung, Microsoft, Google, Nordic, Estimote) without depending on
// the full SIG catalogue. Unknown IDs render as
// ``"manufacturer:0x004C"`` so the brain memory entity still carries
// a discriminator string the orchestrator can search.

private let knownManufacturers: [UInt16: String] = [
    0x004C: "Apple",
    0x0075: "Samsung",
    0x0006: "Microsoft",
    0x00E0: "Google",
    0x0059: "Nordic Semiconductor",
    0x015D: "Estimote",
]

private func decodeManufacturer(data: Data?) -> String {
    guard let data = data, data.count >= 2 else { return "" }
    let companyId = UInt16(data[0]) | (UInt16(data[1]) << 8)
    if let known = knownManufacturers[companyId] {
        return known
    }
    return String(format: "manufacturer:0x%04X", companyId)
}

#endif // canImport(CoreBluetooth)
