import Foundation
import Combine

#if canImport(VeepooBleSDK)
import VeepooBleSDK

/// Real, wired Veepoo wristband vendor adapter. While the device is
/// connected and password-verified, polls HR + SpO2 on a ~10s loop
/// and emits HUP `device_event` frames so the brain sees vitals
/// identical to those from any other adapter.
public final class VeepooAdapterWired: VendorAdapter {

    public let capability: String = "veepoo_wristband"
    public let extraCapabilities: [String] = ["heart_rate", "spo2"]

    private weak var attachedNode: FeralNode?
    private weak var healthStore: HealthStore?
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval
    private var phaseObserver: AnyCancellable?
    private var pollTickCount: UInt = 0
    private var pollInFlight = false

    public init(pollInterval: TimeInterval = 10, healthStore: HealthStore? = nil) {
        self.pollInterval = pollInterval
        self.healthStore = healthStore
    }

    public func setHealthStore(_ store: HealthStore) {
        self.healthStore = store
    }

    // MARK: - VendorAdapter

    public func attach(to node: FeralNode) async throws {
        await MainActor.run {
            _ = VPBleCentralManage.sharedBleManager()
            VeepooSession.shared.installCallbacksIfNeeded()
        }
        self.attachedNode = node

        phaseObserver?.cancel()
        phaseObserver = await MainActor.run {
            VeepooSession.shared.$phase
                .removeDuplicates()
                .sink { [weak self] newPhase in
                    Task { [weak self] in await self?.handlePhaseChange(newPhase) }
                }
        }
        let currentPhase = await MainActor.run { VeepooSession.shared.phase }
        await handlePhaseChange(currentPhase)
    }

    public func detach() async {
        await stopActiveTests()
        await stopPolling()
        phaseObserver?.cancel()
        phaseObserver = nil
        attachedNode = nil
    }

    public func canHandleAction(named name: String) async -> Bool {
        return [
            "health_measure",
            "get_heart_rate", "get_spo2",
            "buzz",
        ].contains(name)
    }

    public func handleAction(frame: HUPFrame, node: FeralNode) async {
        let actionId: String? = {
            if case .string(let s) = frame.payload["action_id"] ?? .null { return s }
            return nil
        }()
        let name: String = {
            if case .string(let s) = frame.payload["name"] ?? .null { return s }
            return ""
        }()
        let params: [String: AnyCodable] = {
            if case .object(let o) = frame.payload["params"] ?? .null { return o }
            return [:]
        }()

        let kind: String = {
            switch name {
            case "get_heart_rate": return "heart_rate"
            case "get_spo2": return "spo2"
            default: break
            }
            if case .string(let s) = params["kind"] ?? .null { return s }
            return "heart_rate"
        }()

        switch kind {
        case "heart_rate": await runHeartRate(actionId: actionId, node: node)
        case "spo2": await runSpO2(actionId: actionId, node: node)
        case "buzz":
            if let actionId = actionId {
                try? await node.sendActionResponse(
                    actionId: actionId, success: true,
                    result: ["note": .string("buzz best-effort; Veepoo haptic API varies by firmware")]
                )
            }
        default:
            if let actionId = actionId {
                try? await node.sendActionResponse(
                    actionId: actionId, success: false,
                    error: "Veepoo adapter does not support kind: \(kind)"
                )
            }
        }
    }

    // MARK: - Action runners

    private func runHeartRate(actionId: String?, node: FeralNode) async {
        guard await isReadyForMeasurement() else {
            if let actionId = actionId {
                try? await node.sendActionResponse(
                    actionId: actionId, success: false,
                    error: "Veepoo wristband not connected"
                )
            }
            return
        }

        switch await measureHeartRate() {
        case .success(let bpm):
            let sampleAt = Date()
            try? await node.emit(eventType: "heart_rate", data: [
                "bpm": .int(bpm),
                "value": .int(bpm),
                "unit": .string("bpm"),
                "source": .string("veepoo_wristband"),
                "heart_rate_source": .string("veepoo_wristband"),
                "heart_rate_sample_ts": .double(sampleAt.timeIntervalSince1970),
            ])
            await recordToHealthStore(
                eventType: "heart_rate",
                data: ["bpm": .int(bpm)],
                sampleAt: sampleAt
            )
            if let actionId = actionId {
                try? await node.sendActionResponse(
                    actionId: actionId, success: true,
                    result: ["bpm": .int(bpm)]
                )
            }
        case .failure(let err):
            if let actionId = actionId {
                try? await node.sendActionResponse(
                    actionId: actionId, success: false,
                    error: err.localizedDescription
                )
            }
        }
    }

    private func runSpO2(actionId: String?, node: FeralNode) async {
        guard await isReadyForMeasurement() else {
            if let actionId = actionId {
                try? await node.sendActionResponse(
                    actionId: actionId, success: false,
                    error: "Veepoo wristband not connected"
                )
            }
            return
        }

        switch await measureSpO2() {
        case .success(let current):
            let sampleAt = Date()
            try? await node.emit(eventType: "spo2", data: [
                "current": .int(current),
                "spo2": .int(current),
                "value": .int(current),
                "unit": .string("%"),
                "source": .string("veepoo_wristband"),
                "spo2_source": .string("veepoo_wristband"),
                "spo2_sample_ts": .double(sampleAt.timeIntervalSince1970),
            ])
            await recordToHealthStore(
                eventType: "spo2",
                data: ["current": .int(current)],
                sampleAt: sampleAt
            )
            if let actionId = actionId {
                try? await node.sendActionResponse(
                    actionId: actionId, success: true,
                    result: ["current": .int(current)]
                )
            }
        case .failure(let err):
            if let actionId = actionId {
                try? await node.sendActionResponse(
                    actionId: actionId, success: false,
                    error: err.localizedDescription
                )
            }
        }
    }

    // MARK: - Veepoo spot tests (demo: VPTestHeartController / VPTestOxygenController)

    private enum MeasureError: LocalizedError {
        case notConnected
        case noSpO2Support
        case notWearing
        case deviceBusy
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Veepoo wristband not connected"
            case .noSpO2Support: return "Device does not support SpO2"
            case .notWearing: return "Wear detection failed"
            case .deviceBusy: return "Device is busy"
            case .timedOut: return "Measurement timed out"
            }
        }
    }

    private func isReadyForMeasurement() async -> Bool {
        await MainActor.run {
            VeepooSession.shared.isDeviceReady
                && (VPBleCentralManage.sharedBleManager()?.isConnected ?? false)
        }
    }

    private func measureHeartRate() async -> Result<Int, MeasureError> {
        await withCheckedContinuation { cont in
            guard let manager = VPBleCentralManage.sharedBleManager() else {
                cont.resume(returning: .failure(.deviceBusy))
                return
            }
            final class Box { var finished = false }
            let box = Box()

            func finish(_ result: Result<Int, MeasureError>) {
                guard !box.finished else { return }
                box.finished = true
                manager.peripheralManage.veepooSDKTestHeartStart(false, testResult: nil)
                cont.resume(returning: result)
            }

            manager.peripheralManage.veepooSDKTestHeartStart(true) { state, value in
                switch state {
                case .testing where value > 0:
                    finish(.success(Int(value)))
                case .notWear:
                    finish(.failure(.notWearing))
                case .deviceBusy:
                    finish(.failure(.deviceBusy))
                case .over:
                    if value > 0 {
                        finish(.success(Int(value)))
                    } else {
                        finish(.failure(.timedOut))
                    }
                default:
                    break
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                finish(.failure(.timedOut))
            }
        }
    }

    private func measureSpO2() async -> Result<Int, MeasureError> {
        let supportsSpO2 = await MainActor.run {
            (VPBleCentralManage.sharedBleManager()?.peripheralModel.oxygenType ?? 0) != 0
        }
        guard supportsSpO2 else { return .failure(.noSpO2Support) }

        return await withCheckedContinuation { cont in
            guard let manager = VPBleCentralManage.sharedBleManager() else {
                cont.resume(returning: .failure(.deviceBusy))
                return
            }
            final class Box { var finished = false }
            let box = Box()

            func finish(_ result: Result<Int, MeasureError>) {
                guard !box.finished else { return }
                box.finished = true
                manager.peripheralManage.veepooSDKTestOxygenStart(false, testResult: nil)
                cont.resume(returning: result)
            }

            manager.peripheralManage.veepooSDKTestOxygenStart(true) { state, value in
                switch state {
                case .testing where value > 0:
                    finish(.success(Int(value)))
                case .notWear:
                    finish(.failure(.notWearing))
                case .deviceBusy:
                    finish(.failure(.deviceBusy))
                case .noFunction:
                    finish(.failure(.noSpO2Support))
                case .over:
                    if value > 0 {
                        finish(.success(Int(value)))
                    } else {
                        finish(.failure(.timedOut))
                    }
                default:
                    break
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                finish(.failure(.timedOut))
            }
        }
    }

    private func stopActiveTests() async {
        await MainActor.run {
            let manage = VPBleCentralManage.sharedBleManager()?.peripheralManage
            manage?.veepooSDKTestHeartStart(false, testResult: nil)
            manage?.veepooSDKTestOxygenStart(false, testResult: nil)
        }
    }

    // MARK: - Local HealthStore fan-out

    private func recordToHealthStore(
        eventType: String, data: [String: AnyCodable], sampleAt: Date
    ) async {
        guard let store = healthStore else { return }
        await MainActor.run {
            store.record(
                eventType: eventType,
                data: data,
                source: "veepoo_wristband",
                pipeline: "Veepoo wristband",
                sampleSource: "Veepoo",
                sampleAt: sampleAt
            )
        }
    }

    // MARK: - Polling

    private func handlePhaseChange(_ phase: VeepooSession.Phase) async {
        switch phase {
        case .ready:
            await startPollingIfNeeded()
            await pollOnce()
        default:
            await stopPolling()
        }
    }

    @MainActor
    private func startPollingIfNeeded() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.pollOnce() }
        }
    }

    @MainActor
    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollTickCount = 0
        pollInFlight = false
    }

    private func pollOnce() async {
        guard let node = attachedNode else { return }
        guard await isReadyForMeasurement() else { return }
        guard !pollInFlight else { return }
        pollInFlight = true
        defer { pollInFlight = false }

        pollTickCount &+= 1
        await runHeartRate(actionId: nil, node: node)
        await runSpO2(actionId: nil, node: node)
    }
}
#endif
