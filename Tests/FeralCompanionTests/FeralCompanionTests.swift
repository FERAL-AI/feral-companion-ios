import XCTest
@testable import FeralCompanion

final class FeralCompanionTests: XCTestCase {
    func testEnvironmentBootstraps() async throws {
        let env = await AppEnvironment.live()
        let status = await env.connection.status
        XCTAssertEqual(status, "disconnected")
        let count = await env.devices.connectedAdapters.count
        XCTAssertEqual(count, 0)
    }
}
