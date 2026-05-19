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
        guard let client = brainClient, let httpBase = client.brainHTTPBase else {
            perceptionText = "Not connected."
            lastError = "Not connected to a brain."
            return
        }
        guard let url = URL(string: "/api/context/live", relativeTo: httpBase) else {
            lastError = "Could not build URL"
            return
        }
        // Audit-r11 fix — Bug 2 (Context tab "Status 401"). The brain
        // gates `/api/context/live` behind `_PHONE_BEARER_GET_PATHS`,
        // so this call MUST carry `Authorization: Bearer phone_bearer`
        // or it 401s and the Context tab dies silent.
        let request = BrainHTTP.authorized(url, bearer: client.phoneBearer)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lastError = "Status \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastError = "Invalid JSON"
                return
            }

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
        } catch {
            lastError = error.localizedDescription
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
