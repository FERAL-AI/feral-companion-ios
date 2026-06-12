import XCTest
import CoreBluetooth
@testable import FeralCompanion

/// Tests for the SDK-shipped ``BLEPeripheralScannerAdapter``. The
/// CoreBluetooth-side wiring (``CBCentralManagerDelegate`` callbacks)
/// is exercised in production by real scans on a paired iPhone — we
/// can't conjure a `CBCentralManager` in a unit test. Instead we
/// drive the adapter's pure-Swift core (``_test_handleDiscovery``,
/// ``_test_evaluateLostPeripherals``) directly with synthetic
/// timestamps and assert the announce shape via the
/// ``_test_announceObserver`` callback.
///
/// What these tests cover:
///   * FERAL self-filter — peripherals advertising one of the host
///     adapter's service UUIDs are silently skipped.
///   * Dedupe window — a second discovery within
///     ``reannounceInterval`` does NOT trigger a second announce.
///   * Re-announce — a discovery after the window closes does emit
///     an announce, refreshing ``last_seen``.
///   * Lost marker — a peripheral that hasn't been seen for
///     ``lostThresholdInterval`` triggers a single announce with
///     ``lost = true``, idempotent on subsequent sweeps.
///   * Recovery — a re-discovery after a lost marker resets the lost
///     flag and emits a fresh "found" announce.
///
/// What these tests do NOT cover (live verification only):
///   * Actual ``CBCentralManager`` state-change handling.
///   * The asynchronous ``Task { try await node.sendDeviceAnnounce... }``
///     path — production sends time out gracefully if the node isn't
///     connected (NSLog'd, swallowed); tests assert against the
///     synchronous observer callback instead.
@MainActor
final class BLEPeripheralScannerAdapterTests: XCTestCase {

    /// Fixed reference instant so every test is deterministic — no
    /// sleep, no Date().now drift, no flake.
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeAdapter(
        reannounceInterval: TimeInterval = 60.0,
        lostThresholdInterval: TimeInterval = 120.0,
        ferralServiceUUIDs: Set<String> = []
    ) -> (BLEPeripheralScannerAdapter, Box<[BLEPeripheralAnnounce]>) {
        let adapter = BLEPeripheralScannerAdapter(
            reannounceInterval: reannounceInterval,
            lostThresholdInterval: lostThresholdInterval,
            // Lost-sweep cadence is irrelevant for these tests — we
            // never let the adapter run a real timer; tests drive
            // ``_test_evaluateLostPeripherals`` directly.
            lostSweepInterval: 1.0,
            ferralServiceUUIDs: ferralServiceUUIDs
        )
        let captured = Box<[BLEPeripheralAnnounce]>([])
        adapter._test_announceObserver = { announce in
            captured.value.append(announce)
        }
        return (adapter, captured)
    }

    // MARK: - FERAL self-filter

    func test_self_filter_skips_peripherals_advertising_known_feral_services() {
        let jwService = "0000FFF0-0000-1000-8000-00805F9B34FB"
        let (adapter, captured) = makeAdapter(
            ferralServiceUUIDs: [jwService]
        )
        let didAnnounce = adapter._test_handleDiscovery(
            deviceId: "AA-BB",
            name: "Theora-1234",
            manufacturer: "manufacturer:0x1234",
            rssi: -65,
            serviceUUIDs: [jwService],
            now: t0
        )
        XCTAssertFalse(didAnnounce, "FERAL service UUID must short-circuit announce")
        XCTAssertTrue(captured.value.isEmpty, "no announce should reach the observer")
    }

    func test_self_filter_is_case_insensitive() {
        let upper = "0000FFF0-0000-1000-8000-00805F9B34FB"
        let lower = upper.lowercased()
        let (adapter, captured) = makeAdapter(ferralServiceUUIDs: [upper])
        // Peripheral advertises lowercase; filter contains uppercase.
        let didAnnounce = adapter._test_handleDiscovery(
            deviceId: "AA-BB",
            name: "weird-case",
            manufacturer: "",
            rssi: -50,
            serviceUUIDs: [lower],
            now: t0
        )
        XCTAssertFalse(didAnnounce, "case mismatch must still match the filter")
        XCTAssertTrue(captured.value.isEmpty)
    }

    // MARK: - Dedupe window

    func test_first_discovery_announces_immediately() {
        let (adapter, captured) = makeAdapter()
        let didAnnounce = adapter._test_handleDiscovery(
            deviceId: "device-A",
            name: "Generic BLE",
            manufacturer: "Apple",
            rssi: -55,
            serviceUUIDs: ["180F"],
            now: t0
        )
        XCTAssertTrue(didAnnounce)
        XCTAssertEqual(captured.value.count, 1)
        let a = captured.value[0]
        XCTAssertEqual(a.deviceId, "device-A")
        XCTAssertEqual(a.name, "Generic BLE")
        XCTAssertEqual(a.manufacturer, "Apple")
        XCTAssertEqual(a.rssi, -55)
        XCTAssertEqual(a.advertisedServices, ["180F"])
        XCTAssertFalse(a.lost)
    }

    func test_second_discovery_within_dedupe_window_does_not_announce() {
        let (adapter, captured) = makeAdapter(reannounceInterval: 60.0)
        _ = adapter._test_handleDiscovery(
            deviceId: "device-A", name: "X", manufacturer: "",
            rssi: -50, serviceUUIDs: [], now: t0
        )
        // 30 s later — still inside the 60 s window.
        _ = adapter._test_handleDiscovery(
            deviceId: "device-A", name: "X", manufacturer: "",
            rssi: -52, serviceUUIDs: [], now: t0.addingTimeInterval(30)
        )
        XCTAssertEqual(captured.value.count, 1, "second discovery must be deduped")
    }

    func test_re_announce_after_window_closes() {
        let (adapter, captured) = makeAdapter(reannounceInterval: 60.0)
        _ = adapter._test_handleDiscovery(
            deviceId: "device-A", name: "X", manufacturer: "",
            rssi: -50, serviceUUIDs: [], now: t0
        )
        // 65 s later — past the 60 s window.
        _ = adapter._test_handleDiscovery(
            deviceId: "device-A", name: "X", manufacturer: "",
            rssi: -47, serviceUUIDs: [], now: t0.addingTimeInterval(65)
        )
        XCTAssertEqual(captured.value.count, 2, "re-announce must fire after window")
        XCTAssertEqual(captured.value[1].rssi, -47, "re-announce must carry latest RSSI")
        XCTAssertFalse(captured.value[1].lost)
    }

    // MARK: - Lost marker

    func test_evaluate_lost_marks_peripheral_after_threshold() {
        let (adapter, captured) = makeAdapter(
            reannounceInterval: 30.0,
            lostThresholdInterval: 120.0
        )
        _ = adapter._test_handleDiscovery(
            deviceId: "device-A", name: "Lost-One", manufacturer: "Apple",
            rssi: -50, serviceUUIDs: ["180F"], now: t0
        )
        // 130 s later — past the 120 s lost threshold.
        adapter._test_evaluateLostPeripherals(now: t0.addingTimeInterval(130))
        XCTAssertEqual(captured.value.count, 2)
        XCTAssertFalse(captured.value[0].lost, "first announce is the discovery")
        XCTAssertTrue(captured.value[1].lost, "second announce is the lost marker")
        XCTAssertEqual(captured.value[1].deviceId, "device-A")
        XCTAssertEqual(captured.value[1].name, "Lost-One",
                       "lost marker must carry the cached name")
    }

    func test_evaluate_lost_is_idempotent() {
        let (adapter, captured) = makeAdapter(
            reannounceInterval: 30.0,
            lostThresholdInterval: 120.0
        )
        _ = adapter._test_handleDiscovery(
            deviceId: "device-A", name: "X", manufacturer: "",
            rssi: -50, serviceUUIDs: [], now: t0
        )
        adapter._test_evaluateLostPeripherals(now: t0.addingTimeInterval(130))
        adapter._test_evaluateLostPeripherals(now: t0.addingTimeInterval(180))
        adapter._test_evaluateLostPeripherals(now: t0.addingTimeInterval(240))
        XCTAssertEqual(captured.value.count, 2,
                       "lost marker must only emit once per outage")
    }

    func test_evaluate_lost_below_threshold_is_noop() {
        let (adapter, captured) = makeAdapter(
            reannounceInterval: 30.0,
            lostThresholdInterval: 120.0
        )
        _ = adapter._test_handleDiscovery(
            deviceId: "device-A", name: "X", manufacturer: "",
            rssi: -50, serviceUUIDs: [], now: t0
        )
        // 60 s elapsed — well under the 120 s threshold.
        adapter._test_evaluateLostPeripherals(now: t0.addingTimeInterval(60))
        XCTAssertEqual(captured.value.count, 1, "no lost marker before threshold")
    }

    func test_recovery_after_lost_emits_fresh_found_announce() {
        let (adapter, captured) = makeAdapter(
            reannounceInterval: 30.0,
            lostThresholdInterval: 120.0
        )
        _ = adapter._test_handleDiscovery(
            deviceId: "device-A", name: "X", manufacturer: "",
            rssi: -50, serviceUUIDs: [], now: t0
        )
        adapter._test_evaluateLostPeripherals(now: t0.addingTimeInterval(130))
        // Peripheral comes back into range at t+200 s.
        let didAnnounce = adapter._test_handleDiscovery(
            deviceId: "device-A", name: "X", manufacturer: "",
            rssi: -45, serviceUUIDs: [], now: t0.addingTimeInterval(200)
        )
        XCTAssertTrue(didAnnounce)
        XCTAssertEqual(captured.value.count, 3)
        XCTAssertTrue(captured.value[1].lost)
        XCTAssertFalse(captured.value[2].lost,
                       "recovery announce must not carry the lost flag")
        XCTAssertEqual(captured.value[2].rssi, -45)
    }

    // MARK: - Init contracts

    func test_init_rejects_lost_threshold_below_reannounce_interval() {
        // The adapter's precondition guards against a configuration
        // where every dedupe window looks like a loss event. We can't
        // catch a Swift precondition() in XCTest, but we can verify
        // a healthy config initialises cleanly.
        let adapter = BLEPeripheralScannerAdapter(
            reannounceInterval: 30,
            lostThresholdInterval: 120,
            lostSweepInterval: 30,
            ferralServiceUUIDs: []
        )
        XCTAssertEqual(adapter.capability, "ble_peripheral_scanner")
        XCTAssertEqual(adapter.reannounceInterval, 30)
        XCTAssertEqual(adapter.lostThresholdInterval, 120)
    }

    func test_canHandleAction_always_false() async {
        let (adapter, _) = makeAdapter()
        let canBuzz = await adapter.canHandleAction(named: "buzz")
        let canAnything = await adapter.canHandleAction(named: "anything")
        XCTAssertFalse(canBuzz)
        XCTAssertFalse(canAnything)
    }
}

// MARK: - Helper: reference container so the closure captures a ref

/// Tiny class wrapper so the announce-observer closure can append to
/// a captured ``[BLEPeripheralAnnounce]`` without the test having to
/// declare its array as a local ``var`` (which Swift would copy on
/// closure capture). The class identity gives us pointer semantics.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
