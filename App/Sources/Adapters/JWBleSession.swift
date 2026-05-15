import Foundation
import SwiftUI
import CoreBluetooth
import JWBle

/// Singleton BLE lifecycle manager for the JieLi W300 glasses.
/// `@MainActor ObservableObject` so SwiftUI views can bind directly
/// to `phase` and `discovered`. JWBle callbacks arrive on arbitrary
/// queues; every mutation hops to MainActor before touching
/// `@Published` state.
@MainActor
public final class JWBleSession: ObservableObject {

    public static let shared = JWBleSession()

    // MARK: - Published State

    public enum Phase: Equatable {
        case idle
        case scanning
        case connecting(name: String)
        case ready(name: String)
        case failed(reason: String)
    }

    public struct Discovered: Identifiable, Equatable {
        public let id: String          // peripheral.identifier.uuidString
        public let name: String
        public let macAddress: String?
        public let rssi: Int
        public let model: JWBleDeviceModel

        public static func == (lhs: Discovered, rhs: Discovered) -> Bool {
            lhs.id == rhs.id && lhs.rssi == rhs.rssi
        }
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var discovered: [Discovered] = []

    // MARK: - Private

    private var callbacksInstalled = false
    private static let lastPeripheralKey = "feral.jwble.lastPeripheralUUID"
    private weak var boundNode: FeralNode?

    private init() {}

    // MARK: - Brain Binding

    /// Wire a FeralNode so the session emits `glasses_status` events
    /// when the BLE phase reaches `.ready` or `.failed`.
    public func bind(brainNode node: FeralNode) {
        boundNode = node
    }

    private func emitGlassesStatus(_ status: String, extra: [String: AnyCodable] = [:]) {
        guard let node = boundNode else { return }
        Task {
            var data: [String: AnyCodable] = [
                "status": .string(status),
                "source": .string("jw_health_glasses"),
            ]
            for (k, v) in extra { data[k] = v }
            try? await node.emit(eventType: "glasses_status", data: data)
        }
    }

    // MARK: - Callback Installation

    /// Install `connectStateChangeCallBack` exactly once. Also ensures
    /// the JWBle SDK is initialized (`setUpWithUid`) so scan/connect
    /// work even if `JWBleAdapterWired.attach(to:)` hasn't run yet
    /// (e.g. user taps Connect before pairing a brain). Idempotent.
    public func installCallbacksIfNeeded() {
        guard !callbacksInstalled else { return }
        callbacksInstalled = true

        JWBleManager.shareInstance().showLog = true
        JWBleManager.shareInstance().checkUserBinding = false
        JWBleManager.shareInstance().setUpWithUid("feral-companion")

        JWBleManager.shareInstance().connectStateChangeCallBack = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.handleConnectStatusChange(status)
            }
        }
        DebugLog.shared.info("jwble: SDK initialized + connectStateChangeCallBack installed")
    }

    private func handleConnectStatusChange(_ status: JWBleDeviceConnectStatus) {
        switch status {
        case .connect:
            DebugLog.shared.info("jwble: status=Connect (BLE pipe open, awaiting bond)")

        case .bondSuccess:
            // Operator report 2026-05-09: W300 firmware bonds + opens
            // every audio characteristic (KEY_SETTING_Audio_RSP visible
            // on FF03) but never emits .syncSuccess. Without that
            // signal our phase stayed at .connecting forever, the
            // Devices tab read "Connecting…", and JWBleAdapterWired's
            // poll loop's `isDeviceConnected()` was happy but the UI
            // looked broken. Promote bond → ready immediately;
            // .syncSuccess (when it does fire) just refreshes the
            // device name. JieLi's docs say syncSuccess is the
            // strict success criterion, but practical observation
            // with W300 is that bond is sufficient for sensor reads.
            let bondName = JWBleManager.shareInstance().connectionModel.deviceName
            DebugLog.shared.success("jwble: status=BondSuccess — promoting to .ready (\(bondName))")
            phase = .ready(name: bondName)
            emitGlassesStatus("ready", extra: [
                "device_name": .string(bondName),
                "promoted_from": .string("bond_success"),
            ])

        case .bondFailure:
            DebugLog.shared.error("jwble: status=BondFailure")
            phase = .failed(reason: "Bond failed — device may be paired to another phone")
            emitGlassesStatus("failed", extra: ["reason": .string("bond_failure")])

        case .syncSuccess:
            let name = JWBleManager.shareInstance().connectionModel.deviceName
            DebugLog.shared.success("jwble: status=SyncSuccess — device ready (\(name))")
            // Idempotent: bondSuccess already promoted us to .ready
            // for W300 firmware that doesn't emit syncSuccess; this
            // path covers devices that DO emit it (and refreshes the
            // device name from the post-sync read).
            phase = .ready(name: name)
            emitGlassesStatus("ready", extra: ["device_name": .string(name)])

        case .syncFailure:
            DebugLog.shared.error("jwble: status=SyncFailure")
            phase = .failed(reason: "Sync failed — could not read device info")
            emitGlassesStatus("failed", extra: ["reason": .string("sync_failure")])

        case .discoverNewUpdateFirm:
            DebugLog.shared.info("jwble: status=DiscoverNewUpdateFirm (ignored)")

        case .batteryUpdate:
            let pwr = JWBleManager.shareInstance().connectionModel.power
            DebugLog.shared.info("jwble: BatteryUpdate power=\(pwr)%")

        case .chargeStatusChanged:
            let charging = JWBleManager.shareInstance().connectionModel.chargIng
            DebugLog.shared.info("jwble: ChargeStatusChanged charging=\(charging)")

        case .headphoneDeviceStatusChanged:
            DebugLog.shared.info("jwble: HeadphoneDeviceStatusChanged")

        case .timeOutDisconnect:
            DebugLog.shared.warning("jwble: TimeOutDisconnect — BLE comm timed out")
            phase = .failed(reason: "Communication timeout — glasses disconnected")
            // Phase-1.5: tell the brain instantly. Without this emit
            // the brain only learned via the 30s heartbeat sweep
            // derating the row to stale; iOS UI was instant but the
            // brain — and therefore the web dashboard — lagged.
            emitGlassesStatus("disconnected", extra: ["reason": .string("timeout_disconnect")])

        case .deviceStatusChanges:
            DebugLog.shared.info("jwble: DeviceStatusChanges")

        case .bondConfirm_NotAllowed:
            DebugLog.shared.error("jwble: BondConfirm_NotAllowed — user denied pairing dialog")
            phase = .failed(reason: "Pairing denied — tap Allow on the Bluetooth pairing dialog")

        case .bondConfirm_TimeOut:
            DebugLog.shared.error("jwble: BondConfirm_TimeOut — user didn't respond to pairing dialog")
            phase = .failed(reason: "Pairing timed out — no response to the Bluetooth dialog")

        case .bleRemovedPairingInformation:
            DebugLog.shared.warning("jwble: BleRemovedPairingInformation — system cache cleared")
            phase = .failed(reason: "System BLE pairing cache was removed")

        case .disConnect:
            DebugLog.shared.warning("jwble: status=DisConnect")
            // Phase-1.5: only report a brain-side disconnect when we
            // were actually mid-link. A `.disConnect` callback in
            // the `.idle` / `.scanning` phase is BLE noise (e.g.
            // user backgrounded the scan modal); emitting then
            // would falsely tell the brain we lost something we
            // never had.
            if case .ready = phase {
                phase = .failed(reason: "Glasses disconnected")
                emitGlassesStatus(
                    "disconnected",
                    extra: ["reason": .string("ble_disconnect_after_ready")],
                )
            } else if case .connecting = phase {
                phase = .failed(reason: "Connection lost during setup")
                emitGlassesStatus(
                    "disconnected",
                    extra: ["reason": .string("ble_disconnect_during_handshake")],
                )
            }

        case .temp:
            DebugLog.shared.info("jwble: status=Temp (ignored)")

        @unknown default:
            DebugLog.shared.info("jwble: unknown status rawValue=\(status.rawValue)")
        }
    }

    // MARK: - Scan

    public func startScanOnly() {
        discovered = []
        phase = .scanning
        DebugLog.shared.info("jwble: starting scan")

        JWBleAction.jwStartScanDevice { [weak self] deviceModel in
            guard let deviceModel = deviceModel else { return }
            Task { @MainActor [weak self] in
                self?.handleDiscoveredDevice(deviceModel)
            }
        }
    }

    private func handleDiscoveredDevice(_ model: JWBleDeviceModel) {
        // Vendor filter: skip rssi == 127 (invalid) and nil/empty names
        guard model.rssi.intValue != 127 else { return }
        let name = model.deviceName
        guard !name.isEmpty else { return }

        let uuid = model.per.identifier.uuidString
        let entry = Discovered(
            id: uuid,
            name: name,
            macAddress: model.macAddress.isEmpty ? nil : model.macAddress,
            rssi: model.rssi.intValue,
            model: model
        )

        // Dedupe by peripheral UUID — update RSSI if already present
        if let idx = discovered.firstIndex(where: { $0.id == uuid }) {
            discovered[idx] = entry
        } else {
            discovered.append(entry)
        }

        // Sort by RSSI descending (strongest first)
        discovered.sort { $0.rssi > $1.rssi }
    }

    public func stopScan() {
        JWBleAction.jwStopScanDevice()
        if case .scanning = phase {
            phase = .idle
        }
        DebugLog.shared.info("jwble: scan stopped")
    }

    // MARK: - Connect

    public func connect(_ entry: Discovered) {
        JWBleAction.jwStopScanDevice()
        phase = .connecting(name: entry.name)
        DebugLog.shared.info("jwble: connecting to \(entry.name) (uuid=\(entry.id))")

        // Persist for auto-reconnect on cold launch
        UserDefaults.standard.set(entry.id, forKey: Self.lastPeripheralKey)

        JWBleAction.jwConnectDevice(entry.model)
    }

    // MARK: - Auto-Reconnect

    public func attemptAutoReconnect() {
        guard let savedUUID = UserDefaults.standard.string(forKey: Self.lastPeripheralKey) else {
            DebugLog.shared.info("jwble: no saved peripheral UUID — skipping auto-reconnect")
            return
        }

        // Already connected or connecting — skip
        if case .ready = phase { return }
        if case .connecting = phase { return }

        // Phase reconciliation: scenePhase: .background drives our
        // local `phase` to `.idle` (via `disconnect()` in the lifecycle
        // hook), but the JWBle SDK keeps the CoreBluetooth pipe open
        // across the app suspend/resume cycle. On `.active`, the SDK
        // still reports `JWBleManager.isConnected == 1` and the
        // CBPeripheral's `state == .connected`, so kicking off a fresh
        // scan + reconnect was redundant — and it spammed the log with
        // a string of `API MISUSE: <CBCentralManager> can only accept
        // this command while in the powered on state` warnings (the
        // SDK calls `connectPeripheral:` before its CB manager has
        // re-asserted `.poweredOn`). Operator log 2026-05-14T23:27:55
        // captured this storm. If the SDK already holds a connected
        // peripheral matching our saved UUID, we just promote `phase`
        // to `.ready` and emit a single status event, skipping the
        // scan path entirely.
        let mgr = JWBleManager.shareInstance()
        // ObjC declarations on `JWBleManager` lack nullability
        // annotations, so Swift sees `connectionModel`, `per`, and
        // `deviceName` as implicitly-unwrapped optionals. Treat them
        // defensively — on a cold launch where the SDK hasn't bound a
        // peripheral yet, `per` can be nil even though the type says
        // otherwise.
        let model: JWBleDeviceModel? = mgr.connectionModel
        let peripheral: CBPeripheral? = model?.per
        if mgr.isConnected,
           let peripheral = peripheral,
           peripheral.identifier.uuidString == savedUUID,
           peripheral.state == .connected {
            let modelName: String? = model?.deviceName
            let name = (modelName?.isEmpty == false ? modelName : nil)
                ?? peripheral.name
                ?? "W300"
            DebugLog.shared.success("jwble: auto-reconnect — SDK already holds \(name) (\(savedUUID)); promoting to .ready without rescan")
            phase = .ready(name: name)
            emitGlassesStatus("ready", extra: [
                "device_name": .string(name),
                "promoted_from": .string("auto_reconnect_already_connected"),
            ])
            return
        }

        DebugLog.shared.info("jwble: auto-reconnect scanning for saved UUID \(savedUUID)")
        discovered = []
        phase = .scanning

        JWBleAction.jwStartScanDevice { [weak self] deviceModel in
            guard let deviceModel = deviceModel else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard case .scanning = self.phase else { return }

                self.handleDiscoveredDevice(deviceModel)

                let uuid = deviceModel.per.identifier.uuidString
                if uuid == savedUUID {
                    let name = deviceModel.deviceName
                    let entry = Discovered(
                        id: uuid,
                        name: name,
                        macAddress: deviceModel.macAddress.isEmpty ? nil : deviceModel.macAddress,
                        rssi: deviceModel.rssi.intValue,
                        model: deviceModel
                    )
                    self.connect(entry)
                }
            }
        }

        // Timeout: stop scanning after 15s if not found
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self = self, case .scanning = self.phase else { return }
            self.stopScan()
            DebugLog.shared.warning("jwble: auto-reconnect timed out — device not found")
        }
    }

    // MARK: - Disconnect

    public func disconnect() {
        JWBleAction.jwDisConnect()
        phase = .idle
        DebugLog.shared.info("jwble: disconnect called")
    }
}
