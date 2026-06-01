import Foundation
import SwiftUI

/// Singleton BLE lifecycle manager for the Veepoo wristband.
/// `@MainActor ObservableObject` so SwiftUI views can bind directly
/// to `phase` and `discovered`. When VeepooBleSDK is absent, methods
/// are no-ops and hardware features report unavailable.
@MainActor
public final class VeepooSession: ObservableObject {

    public static let shared = VeepooSession()

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
        public let id: String          // deviceAddress (MAC-style id from SDK)
        public let name: String
        public let rssi: Int
        #if canImport(VeepooBleSDK)
        let sdkModel: VPPeripheralModel
        #endif

        public static func == (lhs: Discovered, rhs: Discovered) -> Bool {
            lhs.id == rhs.id && lhs.rssi == rhs.rssi
        }
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var discovered: [Discovered] = []

    public static var isSDKAvailable: Bool {
        #if canImport(VeepooBleSDK)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Private

    private var callbacksInstalled = false
    private static let lastDeviceKey = "feral.veepoo.lastDeviceAddress"
    private weak var boundNode: FeralNode?

    private init() {}

    // MARK: - Brain Binding

    public func bind(brainNode node: FeralNode) {
        boundNode = node
    }

    private func emitWristbandStatus(_ status: String, extra: [String: AnyCodable] = [:]) {
        guard let node = boundNode else { return }
        Task {
            var data: [String: AnyCodable] = [
                "status": .string(status),
                "source": .string("veepoo_wristband"),
            ]
            for (k, v) in extra { data[k] = v }
            try? await node.emit(eventType: "wristband_status", data: data)
        }
    }

    // MARK: - Callback Installation

    public func installCallbacksIfNeeded() {
        #if canImport(VeepooBleSDK)
        installCallbacksIfNeededSDK()
        #else
        guard !callbacksInstalled else { return }
        callbacksInstalled = true
        DebugLog.shared.warning("veepoo: SDK not installed — hardware unavailable")
        #endif
    }

    // MARK: - Scan

    public func startScanOnly() {
        #if canImport(VeepooBleSDK)
        startScanOnlySDK()
        #else
        discovered = []
        phase = .failed(reason: Self.sdkUnavailableReason)
        #endif
    }

    public func stopScan() {
        #if canImport(VeepooBleSDK)
        stopScanSDK()
        #else
        if case .scanning = phase {
            phase = .idle
        }
        #endif
    }

    // MARK: - Connect

    public func connect(_ entry: Discovered) {
        #if canImport(VeepooBleSDK)
        connectSDK(entry)
        #else
        phase = .failed(reason: Self.sdkUnavailableReason)
        #endif
    }

    // MARK: - Auto-Reconnect

    public func attemptAutoReconnect() {
        #if canImport(VeepooBleSDK)
        attemptAutoReconnectSDK()
        #endif
    }

    // MARK: - Disconnect

    public func disconnect() {
        #if canImport(VeepooBleSDK)
        disconnectSDK()
        #else
        phase = .idle
        #endif
    }

    /// True when the Veepoo SDK reports an authenticated link.
    public var isDeviceReady: Bool {
        #if canImport(VeepooBleSDK)
        if case .ready = phase { return true }
        return false
        #else
        return false
        #endif
    }
}

#if canImport(VeepooBleSDK)
import VeepooBleSDK

extension VeepooSession {

    fileprivate func installCallbacksIfNeededSDK() {
        guard !callbacksInstalled else { return }
        callbacksInstalled = true

        let manager = VPBleCentralManage.sharedBleManager()
        manager.isLogEnable = true
        manager.isAutoShowPair = true

        manager.VPBleConnectStateChangeBlock = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleConnectStateChange(state)
            }
        }
        DebugLog.shared.info("veepoo: SDK initialized + VPBleConnectStateChangeBlock installed")
    }

    fileprivate func handleConnectStateChange(_ state: VPDeviceConnectState) {
        switch state {
        case .connecting:
            let name = VPBleCentralManage.sharedBleManager().peripheralModel.deviceName
            if case .connecting = phase { return }
            phase = .connecting(name: name)
            DebugLog.shared.info("veepoo: status=Connecting (\(name))")

        case .connect:
            DebugLog.shared.info("veepoo: status=Connect (BLE pipe open, awaiting password)")

        case .verifyPasswordSuccess:
            let name = VPBleCentralManage.sharedBleManager().peripheralModel.deviceName
            DebugLog.shared.success("veepoo: status=VerifyPasswordSuccess — ready (\(name))")
            phase = .ready(name: name)
            emitWristbandStatus("ready", extra: [
                "device_name": .string(name),
            ])

        case .verifyPasswordFailure:
            DebugLog.shared.error("veepoo: status=VerifyPasswordFailure")
            phase = .failed(reason: "Password verification failed — try default PIN 0000")
            emitWristbandStatus("failed", extra: ["reason": .string("verify_password_failure")])

        case .disConnect:
            DebugLog.shared.warning("veepoo: status=DisConnect")
            if case .ready = phase {
                phase = .failed(reason: "Wristband disconnected")
                emitWristbandStatus("disconnected", extra: ["reason": .string("ble_disconnect_after_ready")])
            } else if case .connecting = phase {
                phase = .failed(reason: "Connection lost during setup")
                emitWristbandStatus("disconnected", extra: ["reason": .string("ble_disconnect_during_handshake")])
            }

        case .timeout:
            DebugLog.shared.error("veepoo: status=Timeout")
            phase = .failed(reason: "Connection timed out — move the wristband closer")
            emitWristbandStatus("failed", extra: ["reason": .string("connect_timeout")])

        case .discoverNewUpdateFirm:
            DebugLog.shared.info("veepoo: DiscoverNewUpdateFirm (ignored)")

        @unknown default:
            DebugLog.shared.info("veepoo: unknown VPDeviceConnectState rawValue=\(state.rawValue)")
        }
    }

    fileprivate func startScanOnlySDK() {
        discovered = []
        phase = .scanning
        DebugLog.shared.info("veepoo: starting scan")

        VPBleCentralManage.sharedBleManager().veepooSDKStartScanDeviceAndReceiveScanningDevice { [weak self] model in
            guard let model = model else { return }
            Task { @MainActor [weak self] in
                self?.handleDiscoveredDevice(model)
            }
        }
    }

    fileprivate func handleDiscoveredDevice(_ model: VPPeripheralModel) {
        let name = model.deviceName
        guard !name.isEmpty else { return }

        let address = model.deviceAddress
        guard !address.isEmpty else { return }

        let rssi = model.rssi?.intValue ?? -127
        guard rssi != 127 else { return }

        let entry = Discovered(
            id: address,
            name: name,
            rssi: rssi,
            sdkModel: model
        )

        if let idx = discovered.firstIndex(where: { $0.id == address }) {
            discovered[idx] = entry
        } else {
            discovered.append(entry)
        }

        discovered.sort { $0.rssi > $1.rssi }
    }

    fileprivate func stopScanSDK() {
        VPBleCentralManage.sharedBleManager().veepooSDKStopScanDevice()
        if case .scanning = phase {
            phase = .idle
        }
        DebugLog.shared.info("veepoo: scan stopped")
    }

    fileprivate func connectSDK(_ entry: Discovered) {
        VPBleCentralManage.sharedBleManager().veepooSDKStopScanDevice()
        phase = .connecting(name: entry.name)
        DebugLog.shared.info("veepoo: connecting to \(entry.name) (address=\(entry.id))")

        UserDefaults.standard.set(entry.id, forKey: Self.lastDeviceKey)

        VPBleCentralManage.sharedBleManager().veepooSDKConnectDevice(entry.sdkModel) { [weak self] connectState in
            Task { @MainActor [weak self] in
                self?.handleLegacyConnectBlock(connectState)
            }
        }
    }

    /// `veepooSDKConnectDevice` delivers progress via `DeviceConnectBlock`
    /// in addition to `VPBleConnectStateChangeBlock`.
    fileprivate func handleLegacyConnectBlock(_ state: DeviceConnectState) {
        switch state {
        case .BlePoweredOff:
            phase = .failed(reason: "Bluetooth is off — turn it on in Settings")
        case .BleConnecting:
            break
        case .BleConnectSuccess:
            DebugLog.shared.info("veepoo: BleConnectSuccess (awaiting password)")
        case .BleConnectFailed:
            phase = .failed(reason: "Bluetooth connection failed")
        case .BleVerifyPasswordSuccess:
            let name = VPBleCentralManage.sharedBleManager().peripheralModel.deviceName
            phase = .ready(name: name)
            emitWristbandStatus("ready", extra: ["device_name": .string(name)])
        case .BleVerifyPasswordFailure:
            phase = .failed(reason: "Password verification failed — try default PIN 0000")
        case .BleConnectTimeout:
            phase = .failed(reason: "Connection timed out — move the wristband closer")
        @unknown default:
            break
        }
    }

    fileprivate func attemptAutoReconnectSDK() {
        guard let savedAddress = UserDefaults.standard.string(forKey: Self.lastDeviceKey) else {
            DebugLog.shared.info("veepoo: no saved device address — skipping auto-reconnect")
            return
        }

        if case .ready = phase { return }
        if case .connecting = phase { return }

        DebugLog.shared.info("veepoo: auto-reconnect scanning for saved address \(savedAddress)")
        discovered = []
        phase = .scanning

        VPBleCentralManage.sharedBleManager().veepooSDKStartScanDeviceAndReceiveScanningDevice { [weak self] model in
            guard let model = model else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard case .scanning = self.phase else { return }

                self.handleDiscoveredDevice(model)

                if model.deviceAddress == savedAddress {
                    let entry = Discovered(
                        id: model.deviceAddress,
                        name: model.deviceName,
                        rssi: model.rssi?.intValue ?? -127,
                        sdkModel: model
                    )
                    self.connect(entry)
                }
            }
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self = self, case .scanning = self.phase else { return }
            self.stopScan()
            DebugLog.shared.warning("veepoo: auto-reconnect timed out — device not found")
        }
    }

    fileprivate func disconnectSDK() {
        VPBleCentralManage.sharedBleManager().veepooSDKDisconnectDevice()
        phase = .idle
        DebugLog.shared.info("veepoo: disconnect called")
    }
}
#endif
