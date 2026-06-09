import Foundation
import SwiftUI

/// Singleton BLE lifecycle manager for the JieLi W300 glasses.
/// `@MainActor ObservableObject` so SwiftUI views can bind directly
/// to `phase` and `discovered`. When the proprietary JWBle SDK is
/// absent, methods are no-ops and hardware features report unavailable.
@MainActor
public final class JWBleSession: ObservableObject {

    public static let shared = JWBleSession()

    /// Shown in UI and DeviceStore when the JWBle SDK is not linked.
    public static let sdkUnavailableReason =
        "Vendor SDK not installed — contact Theora for SDK access"

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
        #if canImport(JWBle)
        let sdkModel: JWBleDeviceModel
        #endif

        public static func == (lhs: Discovered, rhs: Discovered) -> Bool {
            lhs.id == rhs.id && lhs.rssi == rhs.rssi
        }
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var discovered: [Discovered] = []

    /// True when the proprietary JWBle.framework is linked into this build.
    public static var isSDKAvailable: Bool {
        #if canImport(JWBle)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Private

    private var callbacksInstalled = false
    /// Guards the one-shot audio-enable + headphone-pairing sequence so we
    /// don't re-pop the iOS Bluetooth pairing dialog on every status
    /// callback. Reset on disconnect so a reconnect re-enables glasses audio.
    private var audioSetupDone = false
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

    public func installCallbacksIfNeeded() {
        #if canImport(JWBle)
        installCallbacksIfNeededSDK()
        #else
        guard !callbacksInstalled else { return }
        callbacksInstalled = true
        DebugLog.shared.warning("jwble: SDK not installed — hardware unavailable")
        #endif
    }

    // MARK: - Scan

    public func startScanOnly() {
        #if canImport(JWBle)
        startScanOnlySDK()
        #else
        discovered = []
        phase = .failed(reason: Self.sdkUnavailableReason)
        #endif
    }

    public func stopScan() {
        #if canImport(JWBle)
        stopScanSDK()
        #else
        if case .scanning = phase {
            phase = .idle
        }
        #endif
    }

    // MARK: - Connect

    public func connect(_ entry: Discovered) {
        #if canImport(JWBle)
        connectSDK(entry)
        #else
        phase = .failed(reason: Self.sdkUnavailableReason)
        #endif
    }

    // MARK: - Auto-Reconnect

    public func attemptAutoReconnect() {
        #if canImport(JWBle)
        attemptAutoReconnectSDK()
        #endif
    }

    // MARK: - Disconnect

    public func disconnect() {
        #if canImport(JWBle)
        disconnectSDK()
        #else
        phase = .idle
        #endif
    }
}

#if canImport(JWBle)
import JWBle

extension JWBleSession {

    fileprivate func installCallbacksIfNeededSDK() {
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

    fileprivate func handleConnectStatusChange(_ status: JWBleDeviceConnectStatus) {
        switch status {
        case .connect:
            DebugLog.shared.info("jwble: status=Connect (BLE pipe open, awaiting bond)")

        case .bondSuccess:
            let bondName = JWBleManager.shareInstance().connectionModel.deviceName
            DebugLog.shared.success("jwble: status=BondSuccess — promoting to .ready (\(bondName))")
            phase = .ready(name: bondName)
            emitGlassesStatus("ready", extra: [
                "device_name": .string(bondName),
                "promoted_from": .string("bond_success"),
            ])
            enableGlassesAudioSDK()

        case .bondFailure:
            DebugLog.shared.error("jwble: status=BondFailure")
            phase = .failed(reason: "Bond failed — device may be paired to another phone")
            emitGlassesStatus("failed", extra: ["reason": .string("bond_failure")])

        case .syncSuccess:
            let name = JWBleManager.shareInstance().connectionModel.deviceName
            DebugLog.shared.success("jwble: status=SyncSuccess — device ready (\(name))")
            phase = .ready(name: name)
            emitGlassesStatus("ready", extra: ["device_name": .string(name)])
            enableGlassesAudioSDK()

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
            readHeadphoneStatusAfterDelaySDK()

        case .timeOutDisconnect:
            DebugLog.shared.warning("jwble: TimeOutDisconnect — BLE comm timed out")
            audioSetupDone = false
            phase = .failed(reason: "Communication timeout — glasses disconnected")
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
            audioSetupDone = false
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

    fileprivate func startScanOnlySDK() {
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

    fileprivate func handleDiscoveredDevice(_ model: JWBleDeviceModel) {
        guard model.rssi.intValue != 127 else { return }
        let name = model.deviceName
        guard !name.isEmpty else { return }

        let uuid = model.per.identifier.uuidString
        let entry = Discovered(
            id: uuid,
            name: name,
            macAddress: model.macAddress.isEmpty ? nil : model.macAddress,
            rssi: model.rssi.intValue,
            sdkModel: model
        )

        if let idx = discovered.firstIndex(where: { $0.id == uuid }) {
            discovered[idx] = entry
        } else {
            discovered.append(entry)
        }

        discovered.sort { $0.rssi > $1.rssi }
    }

    fileprivate func stopScanSDK() {
        JWBleAction.jwStopScanDevice()
        if case .scanning = phase {
            phase = .idle
        }
        DebugLog.shared.info("jwble: scan stopped")
    }

    fileprivate func connectSDK(_ entry: Discovered) {
        JWBleAction.jwStopScanDevice()
        phase = .connecting(name: entry.name)
        DebugLog.shared.info("jwble: connecting to \(entry.name) (uuid=\(entry.id))")

        UserDefaults.standard.set(entry.id, forKey: Self.lastPeripheralKey)

        JWBleAction.jwConnectDevice(entry.sdkModel)
    }

    /// After the glasses reach `.ready`, switch them into classic-Bluetooth
    /// headset mode so iOS exposes a `.bluetoothHFP` route (mic + speaker).
    /// Without this the W300 stays a BLE-sensors-only peripheral and voice
    /// keeps using the iPhone mic/speaker (the "audio stuck on phone" bug).
    ///
    /// Sequence mirrors the vendor reference: enable the audio function
    /// (`jwAudioAction open:YES`), then — only if the headset hasn't been
    /// paired before — kick `jwHeadphonePairing` which pops the iOS
    /// Bluetooth pairing dialog. One-shot per connection (`audioSetupDone`).
    fileprivate func enableGlassesAudioSDK() {
        guard !audioSetupDone else { return }
        audioSetupDone = true

        DebugLog.shared.info("jwble: enabling glasses audio (jwAudioAction open=true)")
        JWBleAction.jwAudioAction(false, open: true) { [weak self] status, open in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                DebugLog.shared.info(
                    "jwble: jwAudioAction result status=\(status.rawValue) open=\(open)"
                )
                let alreadyPaired = JWBleManager.shareInstance().connectionModel.headsetPaired
                if alreadyPaired {
                    DebugLog.shared.info(
                        "jwble: headset already paired — re-asserting audio route"
                    )
                    self.readHeadphoneStatusAfterDelaySDK()
                } else {
                    DebugLog.shared.info(
                        "jwble: initiating headphone pairing (iOS Bluetooth dialog)"
                    )
                    JWBleAction.jwHeadphonePairing()
                }
            }
        }
    }

    /// The SDK updates `connectionModel` asynchronously AFTER the
    /// `.headphoneDeviceStatusChanged` callback fires, so we wait 150ms
    /// (matching the vendor reference) before reading the headset status.
    /// Status 3 (connected) / 4 (connected-to-phone) means the classic-BT
    /// HFP route is live — nudge `W300AudioBridge` so an active voice
    /// session immediately follows the glasses instead of the iPhone.
    fileprivate func readHeadphoneStatusAfterDelaySDK() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self = self else { return }
            let model = JWBleManager.shareInstance().connectionModel
            let st = model.headphoneDeviceStatus
            let paired = model.headsetPaired
            DebugLog.shared.info("jwble: headphone status=\(st) paired=\(paired)")
            // 0=shutdown 1=pairing 2=ready 3=connected 4=connected-to-phone
            if st == 3 || st == 4 {
                W300AudioBridge.shared.reassertRouteIfActive()
                self.emitGlassesStatus("audio_ready", extra: [
                    "headphone_status": .string("\(st)"),
                    "headset_paired": .string(paired ? "true" : "false"),
                ])
            }
        }
    }

    fileprivate func attemptAutoReconnectSDK() {
        guard let savedUUID = UserDefaults.standard.string(forKey: Self.lastPeripheralKey) else {
            DebugLog.shared.info("jwble: no saved peripheral UUID — skipping auto-reconnect")
            return
        }

        if case .ready = phase { return }
        if case .connecting = phase { return }

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
                        sdkModel: deviceModel
                    )
                    self.connect(entry)
                }
            }
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self = self, case .scanning = self.phase else { return }
            self.stopScan()
            DebugLog.shared.warning("jwble: auto-reconnect timed out — device not found")
        }
    }

    fileprivate func disconnectSDK() {
        JWBleAction.jwDisConnect()
        audioSetupDone = false
        phase = .idle
        DebugLog.shared.info("jwble: disconnect called")
    }
}
#endif
