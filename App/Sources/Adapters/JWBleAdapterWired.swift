import Foundation
import Combine

#if canImport(JWBle)
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
    private weak var healthStore: HealthStore?
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval
    private var phaseObserver: AnyCancellable?

    public init(pollInterval: TimeInterval = 10, healthStore: HealthStore? = nil) {
        self.pollInterval = pollInterval
        self.healthStore = healthStore
    }

    /// Audit-r9 brief #06 B1 fix — operator report 2026-05-10:
    /// "vitals page in iOS still showing fake data — sensors not
    /// getting real-time accurate data."
    ///
    /// Root cause: `JWBleAdapterWired` previously emitted W300 reads
    /// only via `node.emit(...)` to the brain, never to the local
    /// `HealthStore`. So the Vitals tab rendered ONLY HealthKit data
    /// (last Apple Watch reading, possibly hours old) regardless of
    /// W300 activity. The new staleness label correctly tagged it as
    /// stale, but the user sees "stale 6h ago" instead of "live · 5s
    /// ago" because the W300 reading never lands in the UI store.
    ///
    /// Fix: same fan-out pattern `HealthKitAdapter.setHealthStore`
    /// uses (`HealthKitAdapter.swift:37-39`). `DeviceStore.activate`
    /// calls this immediately after instantiating the adapter for
    /// `jw_health_glasses`. Each `run*` method writes to BOTH the
    /// brain (`node.emit`) AND the local store (`healthStore.record`)
    /// with explicit `sampleAt: Date()` so the staleness badge shows
    /// "live · 0s ago".
    public func setHealthStore(_ store: HealthStore) {
        self.healthStore = store
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

        // Subscribe to JWBleSession phase transitions so vitals polling
        // starts the moment the W300 reaches `.ready` (post-bond) and
        // stops on disconnect. Operator report 2026-05-09 round 4:
        // never kick jwTestHRAction during bond — only after `.ready`.
        // Combine's sink does not replay the current value, so we also
        // inspect phase once after subscribing (glasses may already be
        // bonded when the brain connects).
        phaseObserver?.cancel()
        phaseObserver = await MainActor.run {
            JWBleSession.shared.$phase
                .removeDuplicates()
                .sink { [weak self] newPhase in
                    Task { [weak self] in await self?.handlePhaseChange(newPhase) }
                }
        }
        let currentPhase = await MainActor.run { JWBleSession.shared.phase }
        await handlePhaseChange(currentPhase)
    }

    public func detach() async {
        await stopPolling()
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
                        let sampleAt = Date()
                        try? await node.emit(eventType: "heart_rate", data: [
                            "bpm": .int(reading.bpm),
                            // Brain accepts flat ``value`` as a fallback
                            // (_handle_biometric_device_event).
                            "value": .int(reading.bpm),
                            "unit": .string("bpm"),
                            "is_wearing": .bool(reading.isWearing),
                            "source": .string("jw_health_glasses"),
                            "heart_rate_source": .string("jw_health_glasses"),
                            "heart_rate_sample_ts": .double(sampleAt.timeIntervalSince1970),
                        ])
                        // Audit-r9 B1: also write to local HealthStore
                        // so the Vitals tab reflects the W300 stream
                        // instead of only HealthKit.
                        await self.recordToHealthStore(
                            eventType: "heart_rate",
                            data: ["bpm": .int(reading.bpm)],
                            sampleAt: sampleAt
                        )
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
                        let sampleAt = Date()
                        try? await node.emit(eventType: "spo2", data: [
                            "current": .int(r.current),
                            "spo2": .int(r.current),
                            "value": .int(r.current),
                            "unit": .string("%"),
                            "high": .int(r.high),
                            "low": .int(r.low),
                            "source": .string("jw_health_glasses"),
                            "spo2_source": .string("jw_health_glasses"),
                            "spo2_sample_ts": .double(sampleAt.timeIntervalSince1970),
                        ])
                        // Audit-r9 B1: also write to local HealthStore.
                        await self.recordToHealthStore(
                            eventType: "spo2",
                            data: ["current": .int(r.current)],
                            sampleAt: sampleAt
                        )
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
                        // Audit-r9 brief #06 B2: previously this emit
                        // omitted `temperature_sample_ts`, so the brain
                        // and Vitals tab tagged W300 temperature reads
                        // as "staleness unknown" even when live.
                        let sampleAt = Date()
                        try? await node.emit(eventType: "temperature", data: [
                            "celsius": .double(Double(r.celsius)),
                            "fahrenheit": .double(Double(r.fahrenheit)),
                            "is_wearing": .bool(r.isWearing),
                            "source": .string("jw_health_glasses"),
                            "temperature_sample_ts": .double(sampleAt.timeIntervalSince1970),
                        ])
                        // Audit-r9 B1: also write to local HealthStore.
                        await self.recordToHealthStore(
                            eventType: "temperature",
                            data: ["celsius": .double(Double(r.celsius))],
                            sampleAt: sampleAt
                        )
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
                        let sampleAt = Date()
                        try? await node.emit(eventType: "steps", data: [
                            "count": .int(r.steps),
                            "distance_m": .int(r.distance),
                            "calories_kcal": .int(r.calories),
                            "source": .string("jw_health_glasses"),
                        ])
                        // Audit-r9 B1: also write to local HealthStore.
                        // Steps don't carry a sample-ts (cumulative
                        // counter); we still pass `sampleAt` so the
                        // staleness label shows "live · 0s ago".
                        await self.recordToHealthStore(
                            eventType: "steps",
                            data: ["count": .int(r.steps)],
                            sampleAt: sampleAt
                        )
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

    // MARK: - Local HealthStore fan-out (audit-r9 brief #06 B1)

    /// Mirror a successful W300 read into the local `HealthStore` so
    /// the Vitals tab reflects glasses data in real time. Mirrors the
    /// pattern in `HealthKitAdapter.emitEverywhere` (~286-300) but
    /// for the BLE path. Always uses `source: "jw_health_glasses"` and
    /// `pipeline: "Theora glasses"` so `MetricCard.sourceLabel` shows
    /// "Theora glasses" instead of the bare capability id.
    private func recordToHealthStore(
        eventType: String, data: [String: AnyCodable], sampleAt: Date
    ) async {
        guard let store = healthStore else { return }
        await MainActor.run {
            store.record(
                eventType: eventType,
                data: data,
                source: "jw_health_glasses",
                pipeline: "Theora glasses",
                sampleSource: "W300",
                sampleAt: sampleAt
            )
        }
    }

    // MARK: - Polling (HR + SpO2 cadence while glasses are .ready)

    private func handlePhaseChange(_ phase: JWBleSession.Phase) async {
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
    }

    private func pollOnce() async {
        guard let node = attachedNode else { return }
        // Phase gate: only poll when JWBleSession is fully `.ready`
        // (post-bond). Sending jwTestHRAction during bond makes the
        // W300 firmware drop the connection.
        let phase = await MainActor.run { JWBleSession.shared.phase }
        guard case .ready = phase else { return }
        guard W300SensorManager.shared.isDeviceConnected() else { return }

        pollTickCount &+= 1
        // HR + SpO2 every tick (10s default). W300SensorManager serialises
        // via busy flags; cache serves repeat polls between spot tests.
        await runHeartRate(actionId: nil, node: node)
        await runSpO2(actionId: nil, node: node)
        // Steps + temperature are lower priority for the Context tab.
        if pollTickCount % 3 == 0 {
            await runSteps(actionId: nil, node: node)
        }
        if pollTickCount % 6 == 0 {
            await runTemperature(actionId: nil, node: node)
        }
    }

    private var pollTickCount: UInt = 0
}
#endif

