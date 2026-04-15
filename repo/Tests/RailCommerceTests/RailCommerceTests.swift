import XCTest
@testable import RailCommerce

final class RailCommerceTests: XCTestCase {
    func testDefaultWiringProducesUsableServices() {
        let app = RailCommerce()
        XCTAssertNotNil(app.checkout)
        XCTAssertNotNil(app.afterSales)
        XCTAssertNotNil(app.messaging)
        XCTAssertNotNil(app.seatInventory)
        XCTAssertNotNil(app.publishing)
        XCTAssertNotNil(app.attachments)
        XCTAssertNotNil(app.talent)
        XCTAssertNotNil(app.lifecycle)
    }

    func testCustomWiringWithFakes() {
        let clock = FakeClock()
        let app = RailCommerce(clock: clock,
                               keychain: InMemoryKeychain(),
                               camera: FakeCamera(granted: true),
                               battery: FakeBattery())
        XCTAssertTrue(app.clock is FakeClock)
    }
}
