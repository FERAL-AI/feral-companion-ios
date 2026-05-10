import Foundation
import CoreBluetooth
import Combine

/// `CBCentralManager` wrapper that publishes the iOS Bluetooth power
/// state. The companion app needs this so the Devices tab can stop
/// claiming "Active" for a Bluetooth peripheral when the user has
/// turned Bluetooth off in iOS Settings or in Control Center.
///
/// Lifecycle:
///
/// * Constructed once by `DeviceStore`. The instance is **inert until
///   `bootstrap()` is called** — instantiating `CBCentralManager`
///   triggers the iOS local-network permission sheet on first launch
///   (per `NSBluetoothAlwaysUsageDescription`), so we delay it until
///   the store is wired into the SwiftUI tree.
/// * `state` is `@Published`; downstream observers (DeviceStore,
///   tests) bind to it via Combine.
/// * The delegate callback hops to the main actor before mutating
///   `state` so SwiftUI reads stay on a single thread.
///
/// We deliberately do **not** start scans or connect to peripherals
/// from this class. Scanning is owned by `JWBleSession`. This monitor
/// only answers the question "is the iOS Bluetooth radio powered on?"
@MainActor
public final class BluetoothSystemMonitor: NSObject, ObservableObject {

    /// Last-known Core Bluetooth power state. `.unknown` until the
    /// first `centralManagerDidUpdateState` callback lands.
    @Published public private(set) var state: CBManagerState = .unknown

    /// `true` only when `state == .poweredOn`. Convenience for binding
    /// without leaking `CoreBluetooth` symbols into views.
    public var isPoweredOn: Bool { state == .poweredOn }

    private var central: CBCentralManager?

    public override init() {
        super.init()
    }

    /// Allocate the underlying `CBCentralManager`. Idempotent —
    /// subsequent calls are no-ops. Must be called from the main
    /// actor (Core Bluetooth requires a main-thread dispatch queue
    /// for `CBManagerStateRestoration` semantics).
    public func bootstrap() {
        if central != nil { return }
        // queue: nil → main queue. Matches the JWBle SDK's expectation
        // and keeps every `@Published` mutation on the main actor.
        // showPowerAlert: false → we handle the "BT off" UI ourselves
        // in DeviceStore so the iOS-default popup doesn't double up
        // with our own "Bluetooth is off" row state.
        let options: [String: Any] = [
            CBCentralManagerOptionShowPowerAlertKey: false,
        ]
        self.central = CBCentralManager(delegate: self, queue: nil, options: options)
    }

    /// Test seam. Production code never calls this; unit tests use
    /// it to drive the state machine without spinning up a real
    /// `CBCentralManager` (which can't be instantiated on a CI host
    /// without the entitlement).
    public func _setStateForTesting(_ newState: CBManagerState) {
        self.state = newState
    }
}

extension BluetoothSystemMonitor: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let snapshot = central.state
        Task { @MainActor [weak self] in
            self?.state = snapshot
        }
    }
}
