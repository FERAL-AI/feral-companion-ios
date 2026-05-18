import XCTest
import CoreBluetooth
@testable import FeralCompanion

final class FeralCompanionTests: XCTestCase {
    /// AppEnvironment bootstraps cleanly and seeds the device catalog
    /// with the universal HealthKit adapter active by default.
    @MainActor
    func testEnvironmentBootstraps() async throws {
        let env = AppEnvironment.live()

        // Fresh install starts unpaired (no saved brain URL).
        let suite = "feral.test.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let conn = ConnectionStore(defaults: testDefaults)
        if case .unpaired = conn.status {
            // ok
        } else {
            XCTFail("fresh ConnectionStore should be .unpaired, got \(conn.status)")
        }

        // Devices are seeded; HealthKit is active by default in
        // AppEnvironment.live().
        XCTAssertFalse(env.devices.entries.isEmpty)
        XCTAssertTrue(env.devices.activeAdapters.contains(where: { $0.capability == "apple_healthkit" }))
    }

    /// Pairing parser accepts the unified v1 shape and the
    /// `https://<brain>/pair?t=…` shortcut.
    func testPairingParserAcceptsUnifiedV1AndShortcut() {
        let unified = #"""
        {"v":1,"mode":"local","url":"http://192.168.1.10:9090","token":"abc-123","brain_id":"brain-x","expires":1800,"name":"home"}
        """#
        let decoded = PairingClient.decode(unified)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.token, "abc-123")
        XCTAssertEqual(decoded?.brainURL.absoluteString, "http://192.168.1.10:9090")

        let shortcut = "https://brain.feral.local:9443/pair?t=token-xyz"
        let d2 = PairingClient.decode(shortcut)
        XCTAssertNotNil(d2)
        XCTAssertEqual(d2?.token, "token-xyz")
    }

    /// Brain URL → WebSocket URL conversion handles both http and https.
    func testWebsocketURLDerivation() {
        let http = URL(string: "http://192.168.1.10:9090")!
        XCTAssertEqual(PairingClient.websocketURL(from: http)?.absoluteString,
                       "ws://192.168.1.10:9090/v1/node")
        let https = URL(string: "https://brain.feral.local")!
        XCTAssertEqual(PairingClient.websocketURL(from: https)?.absoluteString,
                       "wss://brain.feral.local/v1/node")
    }

    // MARK: - Local Network permission gate

    /// Pins the RFC-1918 / .local / link-local classifier driving the
    /// "Open Settings" banner. Any miss here would resurrect the
    /// misleading "Internet connection appears to be offline" string
    /// for users whose brain is on a private LAN.
    func test_isRFC1918OrLocal_classifies_private_addresses() {
        XCTAssertTrue(PairingClient.isRFC1918OrLocal("192.168.18.10"))
        XCTAssertTrue(PairingClient.isRFC1918OrLocal("10.0.0.5"))
        XCTAssertTrue(PairingClient.isRFC1918OrLocal("172.20.5.1"))
        XCTAssertTrue(PairingClient.isRFC1918OrLocal("169.254.5.1"))
        XCTAssertTrue(PairingClient.isRFC1918OrLocal("127.0.0.1"))
        XCTAssertTrue(PairingClient.isRFC1918OrLocal("FeralBrain.local"))
        XCTAssertTrue(PairingClient.isRFC1918OrLocal("localhost"))
        XCTAssertTrue(PairingClient.isRFC1918OrLocal("fe80::1"))

        XCTAssertFalse(PairingClient.isRFC1918OrLocal("8.8.8.8"))
        XCTAssertFalse(PairingClient.isRFC1918OrLocal("172.32.5.1"))
        XCTAssertFalse(PairingClient.isRFC1918OrLocal("api.feral.ai"))
        XCTAssertFalse(PairingClient.isRFC1918OrLocal("203.0.113.7"))
    }

    /// URLError(-1009) "Internet connection appears to be offline" must
    /// map to .localNetworkDenied when the target is on the LAN. Public
    /// hosts pass through untouched so we don't lie about a real outage.
    func test_mapLocalNetworkError_converts_offline_url_error_for_private_hosts() {
        let brain = URL(string: "http://192.168.18.10:9090")!
        let offline = URLError(.notConnectedToInternet)
        let mapped = PairingClient.mapLocalNetworkError(offline, brainURL: brain)
        guard let brainErr = mapped as? BrainClientError,
              case .localNetworkDenied(let host) = brainErr else {
            return XCTFail("expected .localNetworkDenied, got \(mapped)")
        }
        XCTAssertEqual(host, "192.168.18.10")
        XCTAssertTrue(
            brainErr.errorDescription?.contains("Local Network") ?? false,
            "errorDescription should mention Local Network; got \(brainErr.errorDescription ?? "nil")"
        )
    }

    func test_mapLocalNetworkError_passes_through_public_hosts() {
        let public_ = URL(string: "https://api.feral.ai/pair")!
        let offline = URLError(.notConnectedToInternet)
        let mapped = PairingClient.mapLocalNetworkError(offline, brainURL: public_)
        // For real internet outages, surface the underlying URLError
        // verbatim instead of pretending it's a permission issue.
        XCTAssertNotNil(mapped as? URLError)
        XCTAssertNil(mapped as? BrainClientError)
    }

    /// Defensive: a non-URLError (decode error, timeout from BrainClient,
    /// etc.) must NOT be reclassified as a Local Network denial.
    func test_mapLocalNetworkError_ignores_non_URLError() {
        struct Decode: Error {}
        let brain = URL(string: "http://192.168.18.10:9090")!
        let mapped = PairingClient.mapLocalNetworkError(Decode(), brainURL: brain)
        XCTAssertNil(mapped as? BrainClientError)
    }

    @MainActor
    func test_LocalNetworkAuthorization_starts_undetermined() {
        let auth = LocalNetworkAuthorization()
        XCTAssertEqual(auth.state, .undetermined)
        auth.reset()
        XCTAssertEqual(auth.state, .undetermined)
    }

    // MARK: - Phase 1 truthfulness sweep
    //
    // These tests pin the contract that drove Phase 1: a Bluetooth
    // row never reads "Active" unless real transport agrees. The
    // synchronous `DeviceStore.activate` path no longer flips the
    // status to `.active` for BT caps; status is derived from
    // `JWBleSession.phase` + the iOS Bluetooth power state.

    /// Helper: isolate the `feral.activeCapabilities` UserDefaults
    /// key so cold-launch tests don't see real on-device intent.
    @MainActor
    private func makeIsolatedStore(seedActive: [String] = []) -> (DeviceStore, UserDefaults) {
        let suite = "feral.test.devicestore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        if !seedActive.isEmpty {
            defaults.set(seedActive, forKey: "feral.activeCapabilities")
        }
        return (DeviceStore(defaults: defaults), defaults)
    }

    @MainActor
    func test_cold_launch_default_state_treats_bluetooth_as_unknown_off() {
        // Phase-1.5: BluetoothSystemMonitor's first emit is
        // .unknown until CBCentralManager confirms .poweredOn.
        // The DeviceStore must treat that state as "BT row cannot
        // be active yet" — the legacy default of bluetoothPoweredOn
        // = true allowed a row to briefly read .active during a
        // slow CoreBluetooth bring-up.
        let (store, _) = makeIsolatedStore()
        XCTAssertFalse(store.bluetoothPoweredOn)
        store.activate("jw_health_glasses")
        // Without an explicit .poweredOn callback the row reads
        // .failed with a "state unknown" reason.
        guard case .failed(let reason) = store.entries.first(where: { $0.id == "jw_health_glasses" })?.status else {
            return XCTFail("BT row should NOT read .active before CBCentralManager confirms .poweredOn")
        }
        XCTAssertTrue(
            reason.contains("Bluetooth state unknown") || reason.contains("Bluetooth is off"),
            "expected 'Bluetooth state unknown' or 'Bluetooth is off' message, got: \(reason)"
        )
    }

    @MainActor
    func test_applyJWBlePhase_ready_marks_bluetooth_row_active_when_BT_powered_on() {
        let (store, _) = makeIsolatedStore()
        store._applyBluetoothState(.poweredOn)
        store.activate("jw_health_glasses")

        // Activation alone must not lie. With the JWBle session still
        // .idle the row reads .available even though intent is set.
        XCTAssertEqual(
            store.entries.first { $0.id == "jw_health_glasses" }?.status,
            .available,
            "BT row should not flip to .active from activation alone"
        )

        // .ready arrives → row flips.
        store._applyJWBlePhase(.ready(name: "Theora-1234"))
        XCTAssertEqual(
            store.entries.first { $0.id == "jw_health_glasses" }?.status,
            .active
        )
    }

    @MainActor
    func test_applyBluetoothState_off_marks_every_bluetooth_row_failed() {
        let (store, _) = makeIsolatedStore()
        store._applyBluetoothState(.poweredOn)
        store.activate("jw_health_glasses")
        store._applyJWBlePhase(.ready(name: "Theora-1234"))
        XCTAssertEqual(
            store.entries.first { $0.id == "jw_health_glasses" }?.status,
            .active
        )

        // System BT off — the row must flip to .failed even though
        // JWBle hasn't seen the disconnect yet.
        store._applyBluetoothState(.poweredOff)
        guard case .failed(let reason) = store.entries.first(where: { $0.id == "jw_health_glasses" })?.status else {
            return XCTFail("BT row should be .failed when system Bluetooth is off")
        }
        XCTAssertTrue(
            reason.contains("Bluetooth is off"),
            "failure reason should call out BT being off; got: \(reason)"
        )

        // Veepoo + W610 are unsupported; they must NOT be downgraded
        // to a misleading "Bluetooth is off" row — the user can't fix
        // a missing vendor framework by turning BT on.
        guard case .unsupported = store.entries.first(where: { $0.id == "veepoo_wristband" })?.status else {
            return XCTFail("unsupported BT entries must keep their .unsupported reason")
        }
    }

    @MainActor
    func test_cold_launch_with_restored_intent_and_BT_off_does_not_lie() {
        // Simulate a phone that was previously paired and had the
        // Theora capability active — the persisted intent set
        // includes jw_health_glasses. On cold launch with Bluetooth
        // turned off in iOS Settings, the row must NEVER read .active.
        let (store, _) = makeIsolatedStore(seedActive: ["jw_health_glasses"])
        store._applyBluetoothState(.poweredOff)
        store.restoreActiveCapabilities()

        // Adapter is still in the active list so node_register sends
        // the capability — that's intent, not transport claim.
        XCTAssertTrue(store.activeAdapters.contains { $0.capability == "jw_health_glasses" })

        // But the row's UI status must be .failed("Bluetooth is off…").
        guard case .failed(let reason) = store.entries.first(where: { $0.id == "jw_health_glasses" })?.status else {
            return XCTFail("cold-launch + BT-off + restored intent must surface .failed, never .active")
        }
        XCTAssertTrue(reason.contains("Bluetooth is off"))
    }

    @MainActor
    func test_jwble_failed_phase_preserves_reason_text_on_row() {
        let (store, _) = makeIsolatedStore()
        store._applyBluetoothState(.poweredOn)
        store.activate("jw_health_glasses")
        store._applyJWBlePhase(.ready(name: "Theora-1234"))

        // SDK reports a real disconnect reason — we surface it
        // verbatim on the row so the user knows what happened.
        store._applyJWBlePhase(.failed(reason: "Communication timeout — glasses disconnected"))
        guard case .failed(let reason) = store.entries.first(where: { $0.id == "jw_health_glasses" })?.status else {
            return XCTFail("JWBle .failed phase must surface as .failed on the row")
        }
        XCTAssertEqual(reason, "Communication timeout — glasses disconnected")
    }

    @MainActor
    func test_deactivate_bluetooth_clears_intent_and_returns_to_available() {
        let (store, defaults) = makeIsolatedStore()
        store._applyBluetoothState(.poweredOn)
        store.activate("jw_health_glasses")
        store._applyJWBlePhase(.ready(name: "Theora-1234"))
        XCTAssertEqual(
            store.entries.first { $0.id == "jw_health_glasses" }?.status,
            .active
        )

        store.deactivate("jw_health_glasses")
        XCTAssertFalse(store.intent.contains("jw_health_glasses"))
        XCTAssertFalse(store.activeAdapters.contains { $0.capability == "jw_health_glasses" })
        // Persisted intent set no longer carries the capability.
        let saved = defaults.array(forKey: "feral.activeCapabilities") as? [String] ?? []
        XCTAssertFalse(saved.contains("jw_health_glasses"))
        // The row goes back to .available so the Connect button reappears.
        XCTAssertEqual(
            store.entries.first { $0.id == "jw_health_glasses" }?.status,
            .available
        )
    }

    @MainActor
    func test_apple_healthkit_activation_unaffected_by_bluetooth_state() {
        // Non-BT capabilities must not be polluted by the BT
        // derivation. HealthKit reads .active immediately on
        // activate(), regardless of the BT power state.
        let (store, _) = makeIsolatedStore()
        store._applyBluetoothState(.poweredOff)
        store.activate("apple_healthkit")
        XCTAssertEqual(
            store.entries.first { $0.id == "apple_healthkit" }?.status,
            .active
        )
    }

    /// Pin the ``ConnectionStore.connect()`` idempotency guard added
    /// after the 2026-05-08 operator report ("dashboard shows the
    /// same iPhone as multiple paired devices").
    ///
    /// Two paths can race to call ``connect()`` on the same activation:
    /// `applyPairing` auto-connects on success AND
    /// `scenePhase: .active` reconnects whenever ``.paired``. Without
    /// the guard, the brain sees two ``node_register`` round-trips per
    /// pair. The guard short-circuits when the underlying brainClient
    /// is already in ``.connecting`` or ``.connected``.
    @MainActor
    func test_connect_short_circuits_when_brainClient_already_connecting() async {
        let suite = "feral.test.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        // Seed a paired connection store so the early-return guards
        // ("no paired brain") don't fire.
        let url = URL(string: "http://192.168.1.10:9090")!
        testDefaults.set(url.absoluteString, forKey: "feral.brainURL")
        testDefaults.set("test-bearer", forKey: "feral.phoneBearer")

        let conn = ConnectionStore(defaults: testDefaults)

        // Drive brainClient into the in-flight state directly. If the
        // guard regresses, ``connect()`` will pass this point and try
        // a real reachability probe + WS dial, which the test would
        // fail by either taking >>1s or by leaving status in .error.
        conn.brainClient._setStateForTesting(.connecting(brainURL: url))

        let started = Date()
        await conn.connect()
        let elapsed = Date().timeIntervalSince(started)

        // The guard returns synchronously in <50ms. A regressed call
        // would hit `testBrainReachability` (5s URLSession timeout)
        // and at minimum kick the WS open path.
        XCTAssertLessThan(
            elapsed, 0.5,
            "connect() did not short-circuit when brainClient was already .connecting; " +
            "took \(elapsed)s. The idempotency guard in ConnectionStore.connect() likely regressed."
        )
        // Status must NOT have flipped to .error — that would indicate
        // the unreachable-probe branch ran instead of the guard.
        if case .error(let msg) = conn.status {
            XCTFail("connect() ran the full path despite .connecting state, ended in .error: \(msg)")
        }
    }

    @MainActor
    func test_connect_short_circuits_when_brainClient_already_connected() async {
        let suite = "feral.test.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let url = URL(string: "http://192.168.1.10:9090")!
        testDefaults.set(url.absoluteString, forKey: "feral.brainURL")
        testDefaults.set("test-bearer", forKey: "feral.phoneBearer")

        let conn = ConnectionStore(defaults: testDefaults)
        conn.brainClient._setStateForTesting(.connected(brainURL: url, sessionToken: nil))

        let started = Date()
        await conn.connect()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.5, "connect() did not short-circuit when already .connected (took \(elapsed)s)")
        if case .error(let msg) = conn.status {
            XCTFail("connect() should have been a no-op while already .connected; ended in .error: \(msg)")
        }
    }
}
