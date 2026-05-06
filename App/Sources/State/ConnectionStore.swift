import Foundation
import SwiftUI

/// Real `ConnectionStore`. Tracks the user's pairing payload, owns the
/// `BrainClient` lifecycle, and persists the brain URL + phone bearer
/// to UserDefaults so reopening the app reconnects automatically.
@MainActor
public final class ConnectionStore: ObservableObject {

    public enum Status: Equatable {
        case unpaired
        case pairing(message: String)
        case paired(brainURL: URL, nodeId: String)
        case connecting(brainURL: URL)
        case connected(brainURL: URL)
        case reconnecting
        case error(message: String)
    }

    @Published public private(set) var status: Status = .unpaired
    @Published public private(set) var brainURL: URL? = nil
    @Published public private(set) var phoneBearer: String? = nil
    @Published public private(set) var nodeId: String

    public let brainClient: BrainClient
    public let pairingClient: PairingClient
    public let deviceStore: DeviceStore
    public let healthStore: HealthStore

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard,
                brainClient: BrainClient? = nil,
                pairingClient: PairingClient? = nil,
                deviceStore: DeviceStore? = nil,
                healthStore: HealthStore? = nil) {
        self.defaults = defaults
        self.brainClient = brainClient ?? BrainClient()
        self.pairingClient = pairingClient ?? PairingClient()
        self.deviceStore = deviceStore ?? DeviceStore()
        self.healthStore = healthStore ?? HealthStore()

        // Stable per-installation node id.
        if let saved = defaults.string(forKey: "feral.nodeId") {
            self.nodeId = saved
        } else {
            let new = "feral-iphone-\(UUID().uuidString.prefix(8).lowercased())"
            defaults.set(new, forKey: "feral.nodeId")
            self.nodeId = new
        }

        // Restore prior pairing.
        if let urlString = defaults.string(forKey: "feral.brainURL"),
           let url = URL(string: urlString),
           let bearer = defaults.string(forKey: "feral.phoneBearer") {
            self.brainURL = url
            self.phoneBearer = bearer
            self.status = .paired(brainURL: url, nodeId: self.nodeId)
        }
    }

    // MARK: - Pairing flow

    /// Apply a decoded pairing payload — runs check / verify-PIN /
    /// complete and stores the resulting `phone_bearer`.
    public func applyPairing(_ decoded: PairingClient.Decoded, pin: String? = nil) async {
        DebugLog.shared.info("pair: starting at \(decoded.brainURL.absoluteString)")
        status = .pairing(message: "Checking pair URL…")
        do {
            let check = try await pairingClient.checkPair(brainURL: decoded.brainURL, token: decoded.token)
            DebugLog.shared.info("pair: check ok (pin_required=\(check.pin_required))")
            if check.pin_required {
                guard let pin = pin else {
                    status = .pairing(message: "PIN required (\(check.pin_length ?? 6) digits)")
                    return
                }
                try await pairingClient.verifyPin(brainURL: decoded.brainURL, token: decoded.token, pin: pin)
                DebugLog.shared.success("pair: PIN verified")
            }
            let complete = try await pairingClient.completePair(brainURL: decoded.brainURL, token: decoded.token)
            let bearer = complete.phone_bearer ?? decoded.token
            DebugLog.shared.success("pair: complete; bearer length=\(bearer.count) device_id=\(complete.device_id ?? "nil")")

            self.brainURL = decoded.brainURL
            self.phoneBearer = bearer
            self.defaults.set(decoded.brainURL.absoluteString, forKey: "feral.brainURL")
            self.defaults.set(bearer, forKey: "feral.phoneBearer")
            self.status = .paired(brainURL: decoded.brainURL, nodeId: self.nodeId)
        } catch {
            DebugLog.shared.error("pair: failed — \(error.localizedDescription)")
            self.status = .error(message: error.localizedDescription)
        }
    }

    /// HTTP probe to `/health`. Reports the result via DebugLog so the
    /// operator can verify reachability before paying for a full pair.
    public func testBrainReachability(url: URL) async -> Bool {
        DebugLog.shared.info("probe: GET \(url.absoluteString)/health")
        let probe = url.appendingPathComponent("health")
        do {
            var req = URLRequest(url: probe)
            req.timeoutInterval = 5
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse {
                let body = String(data: data, encoding: .utf8) ?? ""
                if (200..<300).contains(http.statusCode) {
                    DebugLog.shared.success("probe: HTTP \(http.statusCode) (\(body.prefix(60)))")
                    return true
                } else {
                    DebugLog.shared.error("probe: HTTP \(http.statusCode)")
                    return false
                }
            }
        } catch {
            DebugLog.shared.error("probe: \(error.localizedDescription)")
        }
        return false
    }

    /// Connect (or reconnect) the brain client using the current
    /// stored brain URL + bearer. Auto-pulls in the loaded adapters.
    public func connect() async {
        guard let brainURL = brainURL, let bearer = phoneBearer else {
            DebugLog.shared.error("connect: no paired brain")
            status = .error(message: "No paired brain.")
            return
        }
        guard let wsURL = PairingClient.websocketURL(from: brainURL) else {
            DebugLog.shared.error("connect: invalid brain URL \(brainURL.absoluteString)")
            status = .error(message: "Invalid brain URL.")
            return
        }
        // Reachability check first — fast feedback if the brain is
        // bound to 127.0.0.1 (or otherwise unreachable from the phone).
        let reachable = await testBrainReachability(url: brainURL)
        if !reachable {
            status = .error(message: "Brain unreachable at \(brainURL.absoluteString). On the Mac, restart with FERAL_HOST=0.0.0.0 and verify the LAN IP from your phone.")
            return
        }
        DebugLog.shared.info("connect: opening WS \(wsURL.absoluteString) with \(deviceStore.activeAdapters.count) adapter(s)")
        status = .connecting(brainURL: brainURL)
        let adapters = deviceStore.activeAdapters
        await brainClient.connect(brainURL: wsURL, apiKey: bearer, nodeId: nodeId, adapters: adapters)
        // BrainClient flips to .connected when node_ack arrives; we
        // mirror its state into ours.
        status = .connected(brainURL: brainURL)
        DebugLog.shared.success("connect: connected to \(brainURL.absoluteString)")
    }

    public func disconnect() async {
        await brainClient.disconnect()
        status = brainURL == nil ? .unpaired : .paired(brainURL: brainURL!, nodeId: nodeId)
    }

    public func unpair() async {
        await brainClient.disconnect()
        defaults.removeObject(forKey: "feral.brainURL")
        defaults.removeObject(forKey: "feral.phoneBearer")
        brainURL = nil
        phoneBearer = nil
        status = .unpaired
    }
}
