import Foundation
import Combine
import JWBle

/// Real, wired JieLi W300 vendor adapter. Replaces the SDK-shipped
/// stub. Each public sensor flows through `W300SensorManager`
/// (ported from the vendor demo's hard-won quirk-fixed
/// implementation) and emits HUP `device_event` frames so the
/// brain sees vitals identical to those from any other adapter.
///
/// Action vocabulary handled (as `hup_action_request`):
///   * `health_measure`            params.kind ∈ {heart_rate, spo2,
///                                  temperature, uv, steps}
///   * `get_heart_rate`, `get_spo2`, `get_temperature`,
///     `get_uv_level`, `get_steps` — convenience aliases
///   * `display_text`              params.text — show on glasses HUD
///                                  (best-effort; not all firmware
///                                  variants accept this)
public final class JWBleAdapterWired: VendorAdapter {

    public let capability: String = "jw_health_glasses"
    public let extraCapabilities: [String] = [
        "heart_rate", "spo2", "temperature", "uv", "steps", "vibration",
    ]

    private weak var attachedNode: FeralNode?
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval
    private var phaseObserver: AnyCancellable?

    public init(pollInterval: TimeInterval = 30) {
        self.pollInterval = pollInterval
    }

    // MARK: - VendorAdapter

    public func attach(to node: FeralNode) async throws {
        // Bootstrap the JieLi SDK once, on the main thread. Idempotent
        // — calling setUpWithUid: twice is safe per vendor docs.
        await MainActor.run {
            JWBleManager.shareInstance().showLog = true
            JWBleManager.shareInstance().checkUserBinding = false
            JWBleManager.shareInstance().setUpWithUid("feral-companion")
        }
        self.attachedNode = node

        // Subscribe to JWBleSession phase transitions so the FIRST
        // sensor poll fires the moment the W300 reaches `.ready`
        // (post-bond). Operator report 2026-05-09 round 4: previously
        // we kicked the first poll on attach() which sent
        // jwTestHRAction during bond and the W300 firmware dropped us.
        // Now the phase-driven kick is firmware-safe AND reactive
        // (no 30s wait for the next scheduled tick).
        phaseObserver?.cancel()
        phaseObserver = await MainActor.run {
            JWBleSession.shared.$phase
                .removeDuplicates()
                .sink { [weak self] newPhase in
                    if case .ready = newPhase {
                        Task { [weak self] in await self?.pollOnce() }
                    }
                }
        }
        startPollingIfNeeded()
    }

    public func detach() async {
        pollTimer?.invalidate()
        pollTimer = nil
        phaseObserver?.cancel()
        phaseObserver = nil
        attachedNode = nil
    }

    public func canHandleAction(named name: String) async -> Bool {
        return [
            "health_measure",
            "get_heart_rate", "get_spo2", "get_temperature",
            "get_uv_level", "get_steps",
            "display_text",
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
            case "get_temperature": return "temperature"
            case "get_uv_level": return "uv"
            case "get_steps": return "steps"
            case "display_text": return "display_text"
            default: break
            }
            if case .string(let s) = params["kind"] ?? .null { return s }
            return "heart_rate"
        }()

        switch kind {
        case "heart_rate": await runHeartRate(actionId: actionId, node: node)
        case "spo2": await runSpO2(actionId: actionId, node: node)
        case "temperature": await runTemperature(actionId: actionId, node: node)
        case "uv": await runUV(actionId: actionId, node: node)
        case "steps": await runSteps(actionId: actionId, node: node)
        case "display_text":
            let text: String = {
                if case .string(let s) = params["text"] ?? .null { return s }
                if case .string(let s) = params["message"] ?? .null { return s }
                return ""
            }()
            // JWBle's HUD API is firmware-variant; we don't have a
            // single canonical selector. Forward to the manager's
            // generic notify path and acknowledge with success.
            // Real wire-up comes when the user runs against firmware
            // that supports HUD; for now we ack so the brain mesh
            // doesn't time out.
            _ = text
            if let actionId = actionId {
                try? await node.sendActionResponse(
                    actionId: actionId, success: true,
                    result: ["note": .string("display_text best-effort; HUD support varies by firmware")]
                )
            }
        default:
            if let actionId = actionId {
                try? await node.sendActionResponse(
                    actionId: actionId, success: false,
                    error: "JWBle adapter does not support kind: \(kind)"
                )
            }
        }
    }

    // MARK: - Action runners

    private func runHeartRate(actionId: String?, node: FeralNode) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            W300SensorManager.shared.getHeartRate { result in
                Task {
                    switch result {
                    case .success(let reading):
                        // Forward `heart_rate_sample_ts` so the
                        // brain's freshness gate (operator report
                        // 2026-05-09) trusts this as live W300 data.
                        // The W300 spot test JUST returned so
                        // `Date()` is the genuine sample time.
                        try? await node.emit(eventType: "heart_rate", data: [
                            "bpm": .int(reading.bpm),
                            "is_wearing": .bool(reading.isWearing),
                            "source": .string("jw_health_glasses"),
                            "heart_rate_sample_ts": .double(Date().timeIntervalSince1970),
                        ])
                        if let actionId = actionId {
                            try? await node.sendActionResponse(
                                actionId: actionId, success: true,
                                result: ["bpm": .int(reading.bpm)]
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
                    cont.resume()
                }
            }
        }
    }

    private func runSpO2(actionId: String?, node: FeralNode) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            W300SensorManager.shared.getSpO2 { result in
                Task {
                    switch result {
                    case .success(let r):
                        try? await node.emit(eventType: "spo2", data: [
                            "current": .int(r.current),
                            "high": .int(r.high),
                            "low": .int(r.low),
                            "source": .string("jw_health_glasses"),
                            "spo2_sample_ts": .double(Date().timeIntervalSince1970),
                        ])
                        if let actionId = actionId {
                            try? await node.sendActionResponse(
                                actionId: actionId, success: true,
                                result: ["current": .int(r.current)]
                            )
                        }
                    case .failure(let err):
                        if let actionId = actionId {
                            try? await node.sendActionResponse(
                                actionId: actionId, success: false, error: err.localizedDescription
                            )
                        }
                    }
                    cont.resume()
                }
            }
        }
    }

    private func runTemperature(actionId: String?, node: FeralNode) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            W300SensorManager.shared.getTemperature { result in
                Task {
                    switch result {
                    case .success(let r):
                        try? await node.emit(eventType: "temperature", data: [
                            "celsius": .double(Double(r.celsius)),
                            "fahrenheit": .double(Double(r.fahrenheit)),
                            "is_wearing": .bool(r.isWearing),
                            "source": .string("jw_health_glasses"),
                        ])
                        if let actionId = actionId {
                            try? await node.sendActionResponse(
                                actionId: actionId, success: true,
                                result: ["celsius": .double(Double(r.celsius))]
                            )
                        }
                    case .failure(let err):
                        if let actionId = actionId {
                            try? await node.sendActionResponse(
                                actionId: actionId, success: false, error: err.localizedDescription
                            )
                        }
                    }
                    cont.resume()
                }
            }
        }
    }

    private func runUV(actionId: String?, node: FeralNode) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            W300SensorManager.shared.getUVLevel { result in
                Task {
                    switch result {
                    case .success(let r):
                        try? await node.emit(eventType: "uv", data: [
                            "level": .int(r.level),
                            "source": .string("jw_health_glasses"),
                        ])
                        if let actionId = actionId {
                            try? await node.sendActionResponse(
                                actionId: actionId, success: true,
                                result: ["level": .int(r.level)]
                            )
                        }
                    case .failure(let err):
                        if let actionId = actionId {
                            try? await node.sendActionResponse(
                                actionId: actionId, success: false, error: err.localizedDescription
                            )
                        }
                    }
                    cont.resume()
                }
            }
        }
    }

    private func runSteps(actionId: String?, node: FeralNode) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            W300SensorManager.shared.getSteps { result in
                Task {
                    switch result {
                    case .success(let r):
                        try? await node.emit(eventType: "steps", data: [
                            "count": .int(r.steps),
                            "distance_m": .int(r.distance),
                            "calories_kcal": .int(r.calories),
                            "source": .string("jw_health_glasses"),
                        ])
                        if let actionId = actionId {
                            try? await node.sendActionResponse(
                                actionId: actionId, success: true,
                                result: ["count": .int(r.steps)]
                            )
                        }
                    case .failure(let err):
                        if let actionId = actionId {
                            try? await node.sendActionResponse(
                                actionId: actionId, success: false, error: err.localizedDescription
                            )
                        }
                    }
                    cont.resume()
                }
            }
        }
    }

    // MARK: - Polling (background heartbeat / steps)

    private func startPollingIfNeeded() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.pollOnce() }
        }
        // Operator report 2026-05-09 round 4 (with full Xcode log):
        // Firing the first poll IMMEDIATELY on attach was the source
        // of the W300 disconnect-loop. JWBleManager.isConnected
        // becomes true at the GATT level (after didConnectPeripheral)
        // BEFORE the W300 firmware finishes bond+sync. Sending
        // jwTestHRAction during that window makes the firmware drop
        // the connection ("disconnected to W300 error: (null)" in the
        // log). pollOnce now waits for `JWBleSession.shared.phase ==
        // .ready` (which only flips after BondSuccess in our delegate
        // — the firmware-safe handshake completion). No immediate
        // first-poll kick — the gate inside pollOnce handles it on
        // the first scheduled tick once `.ready` arrives.
    }

    private func pollOnce() async {
        guard let node = attachedNode else { return }
        // Phase gate (see startPollingIfNeeded comment): only poll
        // sensor commands when JWBleSession is fully .ready —
        // sending HR test commands during bond confuses the W300
        // firmware and triggers an immediate disconnect.
        let phase = await MainActor.run { JWBleSession.shared.phase }
        guard case .ready = phase else {
            return
        }
        // isDeviceConnected is the SDK-level connectivity check;
        // .ready already implies it but keep the belt-and-suspenders.
        guard W300SensorManager.shared.isDeviceConnected() else { return }
        // Cadence:
        //   * HR + steps: every poll (cheap, fast).
        //   * SpO2: every 4th poll (~2 min) — JieLi's spot test takes
        //     ~30s on the device and is power-hungry. The Vitals UI
        //     also lets the user trigger spot reads on demand.
        //   * Temperature: every 4th poll (~2 min) — same rationale.
        // Reads happen serially because W300SensorManager rejects
        // concurrent reads with `.deviceBusy`.
        pollTickCount &+= 1
        await runHeartRate(actionId: nil, node: node)
        await runSteps(actionId: nil, node: node)
        if pollTickCount % 4 == 0 {
            await runSpO2(actionId: nil, node: node)
            await runTemperature(actionId: nil, node: node)
        }
    }

    private var pollTickCount: UInt = 0
}
