import XCTest
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
}
