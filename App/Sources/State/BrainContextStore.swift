import Foundation
import SwiftUI

/// Polls `/api/context/live` to expose what the brain currently
/// "knows" — perception context, sensor state, somatic vector.
/// The Context tab binds to this instead of raw HealthStore metrics.
@MainActor
public final class BrainContextStore: ObservableObject {

    @Published public private(set) var perceptionText: String = ""
    @Published public private(set) var sensors: SensorSnapshot = .empty
    @Published public private(set) var vision: VisionSnapshot = .empty
    @Published public private(set) var somatic: SomaticSnapshot = .empty
    @Published public private(set) var hardwareContext: String = ""
    @Published public private(set) var lastRefreshAt: Date? = nil
    @Published public private(set) var lastError: String? = nil
    /// Structured most-recent failure mode, set alongside ``lastError``
    /// so views can swap "Status 401" for an operator-friendly
    /// explanation. Cleared on every successful refresh.
    @Published public private(set) var lastFailure: BrainHTTPFailure? = nil

    private weak var brainClient: BrainClient?
    private var pollTask: Task<Void, Never>?

    public init() {}

    public func bind(to client: BrainClient) {
        brainClient = client
    }

    public func start(intervalSeconds: Double = 3) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func refresh() async {
        guard let client = brainClient else {
            perceptionText = "Not connected."
            lastError = "Not connected to a brain."
            lastFailure = .transport("Not connected to a brain.")
            return
        }
        let result = await client.authedJSONGET("/api/context/live")
        switch result {
        case .failure(let failure):
            lastFailure = failure
            lastError = failure.userMessage
        case .success(let json):
            perceptionText = (json["perception_text"] as? String) ?? ""
            hardwareContext = (json["hardware_context"] as? String) ?? ""

            if let s = json["sensors"] as? [String: Any] {
                sensors = SensorSnapshot(
                    heartRate: s["heart_rate"] as? Int,
                    heartRateFresh: (s["heart_rate_fresh"] as? Bool) ?? false,
                    heartRateSource: s["heart_rate_source"] as? String,
                    spo2: s["spo2"] as? Int,
                    spo2Fresh: (s["spo2_fresh"] as? Bool) ?? false,
                    temperatureC: s["temperature_c"] as? Double,
                    activityState: s["activity_state"] as? String,
                    batteryPct: s["battery_pct"] as? Int
                )
            }

            if let v = json["vision"] as? [String: Any] {
                vision = VisionSnapshot(
                    active: (v["active"] as? Bool) ?? false,
                    sceneDescription: v["scene_description"] as? String,
                    objects: (v["objects"] as? [String]) ?? [],
                    text: (v["text"] as? [String]) ?? []
                )
            }

            if let sm = json["somatic"] as? [String: Any] {
                somatic = SomaticSnapshot(
                    cognitiveLoad: sm["cognitive_load"] as? Double,
                    activityLevel: sm["activity_level"] as? Double,
                    circadianPhase: sm["circadian_phase"] as? String
                )
            }

            lastRefreshAt = Date()
            lastError = nil
            lastFailure = nil
        }
    }

    // MARK: - Models

    public struct SensorSnapshot: Equatable {
        public let heartRate: Int?
        public let heartRateFresh: Bool
        public let heartRateSource: String?
        public let spo2: Int?
        public let spo2Fresh: Bool
        public let temperatureC: Double?
        public let activityState: String?
        public let batteryPct: Int?

        static let empty = SensorSnapshot(
            heartRate: nil, heartRateFresh: false, heartRateSource: nil,
            spo2: nil, spo2Fresh: false, temperatureC: nil,
            activityState: nil, batteryPct: nil
        )
    }

    public struct VisionSnapshot: Equatable {
        public let active: Bool
        public let sceneDescription: String?
        public let objects: [String]
        public let text: [String]

        static let empty = VisionSnapshot(active: false, sceneDescription: nil, objects: [], text: [])
    }

    public struct SomaticSnapshot: Equatable {
        public let cognitiveLoad: Double?
        public let activityLevel: Double?
        public let circadianPhase: String?

        static let empty = SomaticSnapshot(cognitiveLoad: nil, activityLevel: nil, circadianPhase: nil)
    }
}
