import Foundation
import Combine
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
    private var brainStateCancellable: AnyCancellable?

    /// Re-entry gate for ``connect()``. The state-based check on
    /// ``brainClient.state`` cannot catch the window between
    /// "decide to connect" and "BrainClient flips state to
    /// .connecting" (BrainClient.connect awaits an internal
    /// ``disconnect()`` first, so state stays whatever it was for
    /// tens of milliseconds). Operator log 2026-05-08 showed two
    /// `Daemon connecting` events for the same `device_id` only 91ms
    /// apart, with a `node_bye reason=shutdown` between them — that's
    /// the second connect tearing down the first. This flag closes
    /// the race at the ConnectionStore boundary.
    private var connectInFlight: Bool = false
    /// When the current ``connect()`` attempt started. Used to detect
    /// a stale ``.connecting`` brainClient that never received
    /// ``node_ack`` so foreground reconnect can tear down and retry.
    private var lastConnectStartedAt: Date?
    /// Backoff gate after a WS dial / node_ack failure so rapid
    /// ``scenePhase: .active`` transitions don't hammer the brain.
    private var connectRetryAfter: Date?
    /// How long a ``.connecting`` brainClient is treated as an active
    /// dial before ``connect()`` force-disconnects and retries.
    private static let connectStaleAfterSeconds: TimeInterval = 4.0
    private static let connectRetryBackoffSeconds: TimeInterval = 2.0

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
        // Audit-r14 Lane 11 — bearer storage moved from UserDefaults
        // (unencrypted at rest) to Keychain
        // (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly). The
        // one-shot migration on first launch keeps already-paired
        // users from being logged out by the build that ships this
        // change.
        let migratedBearer = PhoneBearerKeychain.migrateFromUserDefaults(defaults: defaults)
        let storedBearer = PhoneBearerKeychain.load() ?? migratedBearer
        if let urlString = defaults.string(forKey: "feral.brainURL"),
           let url = URL(string: urlString),
           let bearer = storedBearer {
            self.brainURL = url
            self.phoneBearer = bearer
            self.brainClient.phoneBearer = bearer
            self.status = .paired(brainURL: url, nodeId: self.nodeId)
        }

        // Mirror BrainClient.state into our status so the badge,
        // chat send button, and Settings status all read the same
        // truth. Without this, ConnectionStore.status sets eagerly to
        // .connected after `brainClient.connect()` returns even if
        // node_ack hasn't arrived — the source of "have to close+reopen
        // to see connected" reported during live testing.
        self.brainStateCancellable = self.brainClient.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] brainState in
                self?.handleBrainStateChange(brainState)
            }
    }

    private func handleBrainStateChange(_ brainState: BrainClient.State) {
        switch brainState {
        case .connected(let url, _):
            self.status = .connected(brainURL: url)
        case .connecting(let url):
            self.status = .connecting(brainURL: url)
        case .reconnecting:
            self.status = .reconnecting
        case .failed(let m):
            DebugLog.shared.error("brain WS: \(m)")
            // Stay reconnectable when pairing credentials survive —
            // mapping to `.error` would stop ``scenePhase: .active``
            // from calling ``connect()`` again.
            if self.brainURL != nil {
                self.status = .reconnecting
            } else {
                self.status = .error(message: m)
            }
        case .disconnected:
            // Don't downgrade .paired (stored URL+bearer) to .unpaired
            // just because we're not actively connected — pair info
            // survives across connect cycles.
            if let url = self.brainURL {
                self.status = .paired(brainURL: url, nodeId: self.nodeId)
            } else {
                self.status = .unpaired
            }
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
            // Lane 11 (audit-r14): bearer in Keychain, not UserDefaults.
            // The brain URL stays in UserDefaults because it isn't
            // secret and the legacy mDNS lookup path also consumes it.
            PhoneBearerKeychain.save(bearer)
            self.defaults.removeObject(forKey: "feral.phoneBearer")
            self.status = .paired(brainURL: decoded.brainURL, nodeId: self.nodeId)

            // First-pair UX: auto-activate Apple Health so the brain
            // sees a phone with capabilities right away. The user
            // can deactivate it later in the Devices tab if they
            // prefer the W300 path. This also fires the iOS
            // HealthKit auth sheet on first pair so the user gets
            // ONE permission prompt instead of empty Vitals.
            if !deviceStore.activeAdapters.contains(where: { $0.capability == "apple_healthkit" }) {
                DebugLog.shared.info("pair: auto-activating apple_healthkit so the brain sees capabilities")
                deviceStore.activate("apple_healthkit")
            }
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
    ///
    /// **Idempotency**: this is a no-op if the underlying
    /// ``BrainClient`` is already in ``.connecting`` or ``.connected``.
    /// Two paths can race to call ``connect()``:
    ///   1. ``applyPairing`` auto-connects on success.
    ///   2. ``scenePhase: .active`` reconnects whenever ``.paired``.
    /// Both fire on return-from-permission during first-pair, and the
    /// brain previously saw two `node_register` round-trips per pair —
    /// which manifested as duplicate Devices rows on the dashboard
    /// (operator report, 2026-05-08). The guard keeps a single round-
    /// trip without dropping any genuine reconnect attempt (because
    /// .disconnected / .reconnecting / .failed all fall through).
    public func connect() async {
        guard let brainURL = brainURL, let bearer = phoneBearer else {
            DebugLog.shared.error("connect: no paired brain")
            status = .error(message: "No paired brain.")
            return
        }
        if let retryAfter = connectRetryAfter, Date() < retryAfter {
            DebugLog.shared.info(
                "connect: backing off until retry window "
                + "(\(Int(retryAfter.timeIntervalSinceNow))s)"
            )
            return
        }
        // Re-entry gate FIRST — closes the window the state-based
        // guard can't see (see ``connectInFlight`` docstring).
        guard !connectInFlight else {
            DebugLog.shared.info("connect: another connect() is already in flight — skipping duplicate dial")
            return
        }
        switch brainClient.state {
        case .connected:
            DebugLog.shared.info("connect: brainClient already connected — skipping duplicate dial")
            return
        case .connecting:
            if let since = lastConnectStartedAt,
               Date().timeIntervalSince(since) < Self.connectStaleAfterSeconds {
                DebugLog.shared.info("connect: brainClient already connecting — skipping duplicate dial")
                return
            }
            DebugLog.shared.warning("connect: stale .connecting — tearing down socket before retry")
            await brainClient.disconnect()
            lastConnectStartedAt = nil
        case .disconnected, .reconnecting, .failed:
            break
        }
        connectInFlight = true
        defer {
            connectInFlight = false
            lastConnectStartedAt = nil
        }
        lastConnectStartedAt = Date()
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
            connectRetryAfter = Date().addingTimeInterval(Self.connectRetryBackoffSeconds)
            return
        }
        DebugLog.shared.info("connect: opening WS \(wsURL.absoluteString) with \(deviceStore.activeAdapters.count) adapter(s)")
        let adapters = deviceStore.activeAdapters
        await brainClient.connect(brainURL: wsURL, apiKey: bearer, nodeId: nodeId, adapters: adapters)
        // Status flips via the brainClient.$state subscription set up
        // in init — DO NOT eagerly set .connected here. The subscription
        // reads node_ack and is the single source of truth.
        switch brainClient.state {
        case .connected:
            connectRetryAfter = nil
            DebugLog.shared.success("connect: node_ack received — online")
        case .failed(let message):
            connectRetryAfter = Date().addingTimeInterval(Self.connectRetryBackoffSeconds)
            DebugLog.shared.error("connect: failed — \(message); retry in \(Int(Self.connectRetryBackoffSeconds))s")
        default:
            DebugLog.shared.info("connect: handed off to BrainClient; awaiting node_ack")
        }
    }

    /// Test-only seam — marks a recent in-flight connect attempt so
    /// ``connect()`` idempotency tests can simulate a concurrent dial
    /// without opening a real WebSocket.
    func _markConnectAttemptInProgressForTesting() {
        lastConnectStartedAt = Date()
    }

    public func disconnect(reason: String = "user_disconnect") async {
        await brainClient.disconnect(reason: reason)
        status = brainURL == nil ? .unpaired : .paired(brainURL: brainURL!, nodeId: nodeId)
    }

    public func unpair() async {
        await brainClient.disconnect()
        defaults.removeObject(forKey: "feral.brainURL")
        defaults.removeObject(forKey: "feral.phoneBearer")
        // Lane 11 (audit-r14): clear the Keychain entry too so a
        // re-pair flows through completePair and writes a fresh
        // bearer rather than reusing the stale one.
        PhoneBearerKeychain.delete()
        brainURL = nil
        phoneBearer = nil
        status = .unpaired
    }
}
