import Foundation
import CoreBluetooth

/// THESIS_SCENARIOS S3 — peripheral-discovery scanner.
///
/// Watches every BLE peripheral the iPhone observes and forwards each
/// discovery to the brain as a HUP v1.3.0 ``device_announce`` envelope
/// (HUP_SPEC §5.4.4). The brain's hardware mesh upserts a knowledge
/// graph entity (``category=device``) so chat queries like "what BLE
/// devices are around my phone right now?" land on real memory.
///
/// The scanner is observation-only — no GATT connection attempts, no
/// pairing prompts, no notifications. The brain decides what to do
/// with the discovered devices; the phone just reports what it sees.
///
/// Privacy posture:
///
/// * Gated by an explicit Settings toggle —
///   ``UserDefaults.standard.bool(forKey: "feral.ble.peripheral_share")``
///   — off by default. The user must opt in.
/// * Each emit is debounced per peripheral: 60 s minimum between
///   announces for the same device id so the brain's mesh records
///   don't churn on RSSI jitter.
/// * Honors the iOS Bluetooth permission grant. When the user denies
///   Bluetooth access the scanner emits no announces; the
///   ``CBCentralManagerDelegate`` state callback flips ``isActive``
///   to false so the Devices tab can surface the gap.
@MainActor
public final class BLEPeripheralScanner: NSObject, CBCentralManagerDelegate {

    public static let userToggleKey = "feral.ble.peripheral_share"

    private var central: CBCentralManager?
    private weak var node: FeralNode?

    /// Last time we emitted an announce for each device_id. Used to
    /// debounce repeat announces while a peripheral keeps advertising
    /// — the brain only needs one announce per ``deviceDebounceSeconds``
    /// window per device.
    private var lastAnnounce: [String: Date] = [:]
    public let deviceDebounceSeconds: TimeInterval

    /// Public so the Devices tab can render a "Bluetooth: scanning"
    /// row honestly. Flips to true once scanning starts; false on
    /// stop / permission denial / power-off.
    public private(set) var isActive: Bool = false

    public init(deviceDebounceSeconds: TimeInterval = 60.0) {
        self.deviceDebounceSeconds = deviceDebounceSeconds
        super.init()
    }

    /// Start scanning. Idempotent — calling twice is a no-op (the
    /// existing CBCentralManager continues scanning). Returns
    /// immediately; the actual scan begins once Core Bluetooth flips
    /// the manager's state to ``.poweredOn``.
    public func start(emittingTo node: FeralNode) {
        // Honor the opt-in toggle. We refuse to start the scanner
        // even if the host UI asks us to — the toggle is the user's
        // single point of control.
        guard UserDefaults.standard.bool(forKey: Self.userToggleKey) else {
            DebugLog.shared.info(
                "ble_scanner: opt-in toggle is off (feral.ble.peripheral_share); not starting."
            )
            return
        }
        self.node = node
        if central == nil {
            // ``showPowerAlert: false`` so the OS doesn't pop the
            // "Bluetooth is off" alert; the Devices tab surfaces it
            // contextually instead.
            central = CBCentralManager(
                delegate: self,
                queue: nil,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        } else if central?.state == .poweredOn, central?.isScanning == false {
            central?.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            isActive = true
        }
    }

    public func stop() {
        central?.stopScan()
        isActive = false
    }

    // MARK: - CBCentralManagerDelegate

    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            self?.handleStateChange(central.state)
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Capture the values we need from the advertisement BEFORE
        // hopping back onto the main actor — ``advertisementData``
        // is delivered on Core Bluetooth's queue and is not
        // Sendable across actor boundaries.
        let deviceId = peripheral.identifier.uuidString
        let advertisedName =
            advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name
            ?? ""
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let manufacturer = decodeManufacturer(data: manufacturerData)
        let serviceUUIDs =
            (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
                .map { $0.uuidString } ?? []
        let rssiInt = RSSI.intValue

        Task { @MainActor [weak self] in
            self?.handleDiscovery(
                deviceId: deviceId,
                name: advertisedName,
                manufacturer: manufacturer,
                rssi: rssiInt,
                serviceUUIDs: serviceUUIDs
            )
        }
    }

    private func handleStateChange(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            // Only scan if the user opted in. Power-on events happen
            // unconditionally; the toggle gate is repeated here so a
            // device that powers on after we set up the manager
            // doesn't bypass it.
            guard UserDefaults.standard.bool(forKey: Self.userToggleKey) else { return }
            central?.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            isActive = true
        case .poweredOff, .unauthorized, .unsupported, .unknown, .resetting:
            isActive = false
        @unknown default:
            isActive = false
        }
    }

    private func handleDiscovery(
        deviceId: String,
        name: String,
        manufacturer: String,
        rssi: Int,
        serviceUUIDs: [String]
    ) {
        let now = Date()
        if let last = lastAnnounce[deviceId],
           now.timeIntervalSince(last) < deviceDebounceSeconds {
            return
        }
        lastAnnounce[deviceId] = now

        guard let node = node else { return }
        Task {
            do {
                try await node.sendDeviceAnnounce(
                    deviceId: deviceId,
                    deviceKind: "bluetooth_le",
                    name: name,
                    manufacturer: manufacturer,
                    rssiDbm: rssi,
                    advertisedServices: serviceUUIDs
                )
            } catch {
                DebugLog.shared.warning(
                    "ble_scanner: device_announce emit failed for \(deviceId): \(error.localizedDescription)"
                )
            }
        }
    }
}

// MARK: - Manufacturer-data decoder
//
// BLE manufacturer data leads with a 16-bit little-endian
// "Company Identifier" from the Bluetooth SIG's assigned-numbers
// catalogue. We map the operator-visible names FERAL cares about
// (Apple, Samsung, Microsoft, Google) without depending on a
// full catalogue. Unknown IDs render as ``"manufacturer:0x004C"``
// so the brain memory entity still carries a discriminator.

private let knownManufacturers: [UInt16: String] = [
    0x004C: "Apple",
    0x0075: "Samsung",
    0x0006: "Microsoft",
    0x00E0: "Google",
    0x0059: "Nordic Semiconductor",
    0x015D: "Estimote",  // popular BLE-beacon vendor in dev environments
]

private func decodeManufacturer(data: Data?) -> String {
    guard let data = data, data.count >= 2 else { return "" }
    let companyId = UInt16(data[0]) | (UInt16(data[1]) << 8)
    if let known = knownManufacturers[companyId] {
        return known
    }
    return String(format: "manufacturer:0x%04X", companyId)
}
