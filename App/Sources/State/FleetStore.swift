import Foundation
import SwiftUI

// HUP fleet (server-driven hardware hub) — visibility into every
// SELF-DESCRIBING device the brain knows about, rendered entirely from
// the brain's `GET /api/hardware/fleet` response. No device is hardcoded
// here: a brand-new device that registers with the brain (a robot, a
// second pair of glasses, a wristband) shows up as a card automatically,
// with its own capabilities, safety badges, and live "honesty loop" state.
//
// This is additive to `BrainCapabilitiesStore` (which polls
// `/api/capabilities` for routable node actions). The fleet view is about
// the physical devices + their verified action outcomes — the demo's
// "plug in any device, zero code" + "firmware said OK, telemetry says it
// didn't move → verified ✗" story.

/// One capability as the brain self-described it. All fields come from the
/// device's own manifest — the app types none of them.
public struct FleetCapability: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let category: String
    public let permissionTier: String
    public let safetyTier: String          // safe | confirm | deny (generic resolver)
    public let readOnly: Bool
    public let requiresApproval: Bool
    public let requiresConfirmation: Bool
    public let reversible: Bool
    public let rateLimitPerMinute: Int?
    public let hasVerify: Bool
    public let paramNames: [String]
}

/// The last action+verify outcome for a device — the live honesty strip.
public struct FleetVerification: Equatable {
    public let capability: String
    public let success: Bool
    public let verified: Bool?   // true / false / nil ("unknown")
    public let observed: String?
    public let expected: [String]
    public let error: String?

    /// Human-facing honesty verdict for the UI strip.
    public var verdict: String {
        if let v = verified {
            return v ? "verified ✓" : "verified ✗"
        }
        return success ? "done (unverified)" : "failed"
    }
}

/// One device in the brain's fleet, fully described by the server.
public struct FleetDevice: Identifiable, Equatable {
    public let id: String       // device_id
    public let name: String
    public let deviceType: String
    public let manufacturer: String
    public let model: String
    public let connectionType: String
    public let location: String
    public let batteryPowered: Bool
    public let sensors: [String]
    public let actuators: [String]
    public let capabilities: [FleetCapability]
    public let lastVerified: FleetVerification?
}

@MainActor
public final class FleetStore: ObservableObject {

    @Published public private(set) var devices: [FleetDevice] = []
    @Published public private(set) var meshNodeCount: Int = 0
    @Published public private(set) var announcedCount: Int = 0
    @Published public private(set) var lastRefreshError: String? = nil
    @Published public private(set) var lastRefreshAt: Date? = nil

    private weak var brainClient: BrainClient?
    private var pollTask: Task<Void, Never>?

    public init() {}

    public func bind(to client: BrainClient) {
        brainClient = client
    }

    public func start(intervalSeconds: Double = 5) {
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
        guard let httpBase = brainClient?.brainHTTPBase else {
            devices = []
            lastRefreshError = "Not connected to a brain."
            return
        }
        guard let url = URL(string: "/api/hardware/fleet", relativeTo: httpBase) else {
            lastRefreshError = "Could not build /api/hardware/fleet URL"
            return
        }
        do {
            let req = BrainHTTP.authorized(url, bearer: brainClient?.phoneBearer, method: .get)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lastRefreshError = "Brain returned status \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastRefreshError = "Brain response wasn't JSON"
                return
            }
            devices = Self.parseDevices(json["devices"] as? [[String: Any]] ?? [])
            if let mesh = json["mesh"] as? [String: Any] {
                meshNodeCount = (mesh["nodes"] as? [Any])?.count ?? 0
                announcedCount = (mesh["announced_devices"] as? [Any])?.count ?? 0
            }
            lastRefreshAt = Date()
            lastRefreshError = nil
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    // MARK: - Parsing

    static func parseDevices(_ raw: [[String: Any]]) -> [FleetDevice] {
        raw.compactMap { dict in
            guard let id = dict["device_id"] as? String else { return nil }
            let caps = (dict["capabilities"] as? [[String: Any]] ?? []).map(parseCapability)
            return FleetDevice(
                id: id,
                name: (dict["name"] as? String) ?? id,
                deviceType: (dict["device_type"] as? String) ?? "device",
                manufacturer: (dict["manufacturer"] as? String) ?? "",
                model: (dict["model"] as? String) ?? "",
                connectionType: (dict["connection_type"] as? String) ?? "",
                location: (dict["location"] as? String) ?? "",
                batteryPowered: (dict["battery_powered"] as? Bool) ?? false,
                sensors: (dict["sensors"] as? [String]) ?? [],
                actuators: (dict["actuators"] as? [String]) ?? [],
                capabilities: caps,
                lastVerified: parseVerification(dict["last_verified"] as? [String: Any])
            )
        }
    }

    static func parseCapability(_ d: [String: Any]) -> FleetCapability {
        let params = (d["params"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return FleetCapability(
            id: (d["id"] as? String) ?? "",
            name: (d["name"] as? String) ?? (d["id"] as? String) ?? "",
            description: (d["description"] as? String) ?? "",
            category: (d["category"] as? String) ?? "",
            permissionTier: (d["permission_tier"] as? String) ?? "passive",
            safetyTier: (d["safety_tier"] as? String) ?? "safe",
            readOnly: (d["read_only"] as? Bool) ?? false,
            requiresApproval: (d["requires_approval"] as? Bool) ?? false,
            requiresConfirmation: (d["requires_confirmation"] as? Bool) ?? false,
            reversible: (d["reversible"] as? Bool) ?? true,
            rateLimitPerMinute: d["rate_limit_per_minute"] as? Int,
            hasVerify: (d["has_verify"] as? Bool) ?? false,
            paramNames: params
        )
    }

    static func parseVerification(_ d: [String: Any]?) -> FleetVerification? {
        guard let d = d else { return nil }
        return FleetVerification(
            capability: (d["capability"] as? String) ?? "",
            success: (d["success"] as? Bool) ?? false,
            verified: d["verified"] as? Bool,
            observed: d["observed"].map { "\($0)" },
            expected: (d["expected"] as? [Any])?.map { "\($0)" } ?? [],
            error: d["error"] as? String
        )
    }
}
