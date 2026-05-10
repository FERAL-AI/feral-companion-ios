import Foundation
import HealthKit

/// First fully-wired vendor adapter. Reads core vitals from Apple
/// HealthKit and emits them to the brain as HUP `device_event`
/// frames with the canonical `event_type` strings (heart_rate,
/// spo2, steps, sleep_hours).
///
/// HealthKit aggregates data from any source the user has authorised:
/// Apple Watch, Whoop, Garmin, Fitbit, Oura, Polar — anything that
/// writes to the system Health database. So a single adapter covers
/// every "I have a wearable that syncs to Apple Health" user.
@MainActor
public final class HealthKitAdapter: VendorAdapter {

    public let capability: String = "apple_healthkit"

    /// Secondary capability strings advertised alongside the primary.
    public let extraCapabilities: [String] = [
        "heart_rate", "spo2", "steps", "sleep", "temperature", "hrv",
    ]

    private let store = HKHealthStore()
    private weak var attachedNode: FeralNode?
    private weak var healthStore: HealthStore?
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval
    private var permissionsGranted = false

    public init(pollInterval: TimeInterval = 30, healthStore: HealthStore? = nil) {
        self.pollInterval = pollInterval
        self.healthStore = healthStore
    }

    /// Inject the app's `HealthStore` so device-event emits also surface
    /// in the Vitals UI (without waiting for the brain to round-trip).
    public func setHealthStore(_ store: HealthStore) {
        self.healthStore = store
    }

    /// Preflight permission grant. Callable from `DeviceStore.activate`
    /// BEFORE a brain is connected, so the user sees the standard iOS
    /// HealthKit auth sheet immediately instead of after pairing.
    /// Also kicks off a one-shot read so the Vitals tab populates
    /// without waiting for the brain handshake.
    public func requestPermissionsAndPrime() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw FeralNodeError.permissionDenied(
                capability: capability,
                reason: "HealthKit is not available on this device"
            )
        }
        let toRead: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!,
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            HKObjectType.quantityType(forIdentifier: .bodyTemperature)!,
            HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!,
        ]
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: nil, read: toRead) { success, error in
                if let error = error {
                    cont.resume(throwing: FeralNodeError.permissionDenied(
                        capability: self.capability,
                        reason: "HealthKit auth error: \(error.localizedDescription)"
                    ))
                } else if !success {
                    cont.resume(throwing: FeralNodeError.permissionDenied(
                        capability: self.capability,
                        reason: "User declined HealthKit access"
                    ))
                } else {
                    cont.resume(returning: ())
                }
            }
        }
        permissionsGranted = true

        // Prime the UI with one read pass right now — without a brain
        // we can still populate the Vitals tab.
        await readToHealthStore()
    }

    private func readToHealthStore() async {
        if let r = try? await readLatestHeartRateWithSource() {
            await MainActor.run {
                self.healthStore?.record(
                    eventType: "heart_rate",
                    data: ["bpm": .int(Int(r.value))],
                    source: "apple_healthkit",
                    pipeline: "Apple Health",
                    sampleSource: r.sampleSource,
                    sampleAt: r.sampleEndDate
                )
            }
        }
        if let r = try? await readLatestSpO2WithSource() {
            await MainActor.run {
                self.healthStore?.record(
                    eventType: "spo2",
                    data: ["current": .int(Int(r.value * 100))],
                    source: "apple_healthkit",
                    pipeline: "Apple Health",
                    sampleSource: r.sampleSource,
                    sampleAt: r.sampleEndDate
                )
            }
        }
        if let steps = try? await readTodaysSteps() {
            await MainActor.run {
                self.healthStore?.record(
                    eventType: "steps",
                    data: ["count": .int(steps)],
                    source: "apple_healthkit",
                    pipeline: "Apple Health",
                    // HKStatisticsQuery does not carry per-sample
                    // source revisions; the cumulative day total can
                    // span multiple devices. Leave sampleSource empty
                    // so Vitals shows "Apple Health" alone — truthful
                    // about the pipeline, no invented sample-source.
                    sampleSource: ""
                )
            }
        }
    }

    // MARK: - VendorAdapter

    public func attach(to node: FeralNode) async throws {
        self.attachedNode = node
        // If the activation flow already ran requestPermissionsAndPrime,
        // skip re-asking. Otherwise do it now (lazy path for adapters
        // that were never pre-activated).
        if !permissionsGranted {
            try await requestPermissionsAndPrime()
        }
        startPolling()
    }

    public func detach() async {
        pollTimer?.invalidate()
        pollTimer = nil
        attachedNode = nil
    }

    public func canHandleAction(named name: String) async -> Bool {
        ["health_measure", "get_heart_rate", "get_spo2", "get_steps"].contains(name)
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

        let kind: String = {
            switch name {
            case "get_heart_rate": return "heart_rate"
            case "get_spo2": return "spo2"
            case "get_steps": return "steps"
            default: break
            }
            if case .object(let params) = frame.payload["params"] ?? .null,
               case .string(let s) = params["kind"] ?? .null {
                return s
            }
            return "heart_rate"
        }()

        do {
            switch kind {
            case "heart_rate":
                let bpm = try await readLatestHeartRate()
                if let actionId = actionId {
                    try? await node.sendActionResponse(
                        actionId: actionId,
                        success: true,
                        result: ["bpm": .int(Int(bpm))]
                    )
                }
                try? await node.emit(eventType: "heart_rate", data: [
                    "bpm": .int(Int(bpm)),
                    "source": .string("apple_healthkit"),
                ])
            case "spo2":
                let sat = try await readLatestSpO2()
                let pct = Int(sat * 100)
                if let actionId = actionId {
                    try? await node.sendActionResponse(
                        actionId: actionId,
                        success: true,
                        result: ["current": .int(pct)]
                    )
                }
                try? await node.emit(eventType: "spo2", data: [
                    "current": .int(pct),
                    "source": .string("apple_healthkit"),
                ])
            case "steps":
                let steps = try await readTodaysSteps()
                if let actionId = actionId {
                    try? await node.sendActionResponse(
                        actionId: actionId,
                        success: true,
                        result: ["count": .int(steps)]
                    )
                }
                try? await node.emit(eventType: "steps", data: [
                    "count": .int(steps),
                    "source": .string("apple_healthkit"),
                ])
            default:
                if let actionId = actionId {
                    try? await node.sendActionResponse(
                        actionId: actionId, success: false,
                        error: "HealthKitAdapter does not support kind: \(kind)"
                    )
                }
            }
        } catch {
            if let actionId = actionId {
                try? await node.sendActionResponse(
                    actionId: actionId, success: false,
                    error: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.pollOnce() }
        }
        Task { await pollOnce() }
    }

    private func pollOnce() async {
        if let r = try? await readLatestHeartRateWithSource() {
            await emitEverywhere(
                eventType: "heart_rate",
                data: [
                    "bpm": .int(Int(r.value)),
                    // Forward HKSample.endDate so the brain's
                    // proactive engine can gate alerts on freshness
                    // (operator report 2026-05-09: stale HR fired
                    // phantom Heart Rate Alert). Brain reads
                    // ``heart_rate_sample_ts`` in
                    // perception/fusion.update_sensors.
                    "heart_rate_sample_ts": .double(r.sampleEndDate.timeIntervalSince1970),
                ],
                sampleSource: r.sampleSource
            )
        }
        if let r = try? await readLatestSpO2WithSource() {
            await emitEverywhere(
                eventType: "spo2",
                data: [
                    "current": .int(Int(r.value * 100)),
                    "spo2_sample_ts": .double(r.sampleEndDate.timeIntervalSince1970),
                ],
                sampleSource: r.sampleSource
            )
        }
        if let steps = try? await readTodaysSteps() {
            await emitEverywhere(
                eventType: "steps",
                data: ["count": .int(steps)],
                sampleSource: ""
            )
        }
    }

    /// Fan-out: write to the local HealthStore (so Vitals UI updates
    /// even without a brain) AND emit to the brain if connected.
    /// ``sampleSource`` is the HealthKit sample-source name extracted
    /// from ``HKQuantitySample.sourceRevision`` so the Vitals tab can
    /// render ``"Apple Health · Apple Watch"`` without inventing the
    /// device name.
    private func emitEverywhere(
        eventType: String,
        data: [String: AnyCodable],
        sampleSource: String = ""
    ) async {
        await MainActor.run {
            self.healthStore?.record(
                eventType: eventType,
                data: data,
                source: "apple_healthkit",
                pipeline: "Apple Health",
                sampleSource: sampleSource
            )
        }
        if let node = attachedNode {
            var payload = data
            payload["source"] = .string("apple_healthkit")
            payload["pipeline"] = .string("Apple Health")
            if !sampleSource.isEmpty {
                payload["sample_source"] = .string(sampleSource)
            }
            try? await node.emit(eventType: eventType, data: payload)
        }
    }

    // MARK: - HK queries

    /// Lightweight tuple used by every per-metric reader so the
    /// HealthKit sample-source name AND the sample's recorded
    /// timestamp reach Vitals + the brain without a second query.
    /// ``sampleEndDate`` is forwarded to the brain as
    /// ``*_sample_ts`` so the proactive engine can gate alerts on
    /// freshness — operator report 2026-05-09 caught a stale
    /// HealthKit HR (115 bpm, hours old) firing as if it were a
    /// real-time alert.
    private struct SampledReading {
        let value: Double
        let sampleSource: String
        let sampleEndDate: Date
    }

    private func readLatestHeartRate() async throws -> Double {
        let type = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        return try await readLatestQuantity(type: type, unit: HKUnit(from: "count/min"))
    }

    private func readLatestHeartRateWithSource() async throws -> SampledReading {
        let type = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        return try await readLatestSampledReading(type: type, unit: HKUnit(from: "count/min"))
    }

    private func readLatestSpO2() async throws -> Double {
        let type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation)!
        return try await readLatestQuantity(type: type, unit: HKUnit.percent())
    }

    private func readLatestSpO2WithSource() async throws -> SampledReading {
        let type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation)!
        return try await readLatestSampledReading(type: type, unit: HKUnit.percent())
    }

    private func readTodaysSteps() async throws -> Int {
        let type = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [])
        return try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                if let error = error { cont.resume(throwing: error); return }
                let v = result?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                cont.resume(returning: Int(v))
            }
            store.execute(q)
        }
    }

    private func readLatestQuantity(type: HKQuantityType, unit: HKUnit) async throws -> Double {
        try await readLatestSampledReading(type: type, unit: unit).value
    }

    private func readLatestSampledReading(type: HKQuantityType, unit: HKUnit) async throws -> SampledReading {
        try await withCheckedThrowingContinuation { cont in
            let sortByDate = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let q = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sortByDate]) { _, samples, error in
                if let error = error { cont.resume(throwing: error); return }
                guard let sample = samples?.first as? HKQuantitySample else {
                    cont.resume(throwing: NSError(domain: "HealthKitAdapter", code: -2,
                                                  userInfo: [NSLocalizedDescriptionKey: "no samples for \(type.identifier)"]))
                    return
                }
                let sourceName = sample.sourceRevision.source.name
                cont.resume(returning: SampledReading(
                    value: sample.quantity.doubleValue(for: unit),
                    sampleSource: sourceName,
                    sampleEndDate: sample.endDate
                ))
            }
            store.execute(q)
        }
    }
}
