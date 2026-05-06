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
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval

    public init(pollInterval: TimeInterval = 30) {
        self.pollInterval = pollInterval
    }

    // MARK: - VendorAdapter

    public func attach(to node: FeralNode) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw FeralNodeError.permissionDenied(
                capability: capability,
                reason: "HealthKit is not available on this device"
            )
        }
        self.attachedNode = node

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
        guard let node = attachedNode else { return }
        if let bpm = try? await readLatestHeartRate() {
            try? await node.emit(eventType: "heart_rate", data: [
                "bpm": .int(Int(bpm)),
                "source": .string("apple_healthkit"),
            ])
        }
        if let sat = try? await readLatestSpO2() {
            try? await node.emit(eventType: "spo2", data: [
                "current": .int(Int(sat * 100)),
                "source": .string("apple_healthkit"),
            ])
        }
        if let steps = try? await readTodaysSteps() {
            try? await node.emit(eventType: "steps", data: [
                "count": .int(steps),
                "source": .string("apple_healthkit"),
            ])
        }
    }

    // MARK: - HK queries

    private func readLatestHeartRate() async throws -> Double {
        let type = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        return try await readLatestQuantity(type: type, unit: HKUnit(from: "count/min"))
    }

    private func readLatestSpO2() async throws -> Double {
        let type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation)!
        return try await readLatestQuantity(type: type, unit: HKUnit.percent())
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
        try await withCheckedThrowingContinuation { cont in
            let sortByDate = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let q = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sortByDate]) { _, samples, error in
                if let error = error { cont.resume(throwing: error); return }
                guard let sample = samples?.first as? HKQuantitySample else {
                    cont.resume(throwing: NSError(domain: "HealthKitAdapter", code: -2,
                                                  userInfo: [NSLocalizedDescriptionKey: "no samples for \(type.identifier)"]))
                    return
                }
                cont.resume(returning: sample.quantity.doubleValue(for: unit))
            }
            store.execute(q)
        }
    }
}
