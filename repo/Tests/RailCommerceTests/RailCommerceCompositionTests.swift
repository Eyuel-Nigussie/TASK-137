import XCTest
@testable import RailCommerce

/// End-to-end tests for the `RailCommerce` composition root — verifies that every
/// service is constructed, all share the injected providers, and the container can
/// run an end-to-end customer flow without the app layer.
final class RailCommerceCompositionTests: XCTestCase {

    func testContainerWiresAllServices() {
        let app = RailCommerce()
        XCTAssertNotNil(app.catalog)
        XCTAssertNotNil(app.cart)
        XCTAssertNotNil(app.addressBook)
        XCTAssertNotNil(app.checkout)
        XCTAssertNotNil(app.afterSales)
        XCTAssertNotNil(app.messaging)
        XCTAssertNotNil(app.seatInventory)
        XCTAssertNotNil(app.publishing)
        XCTAssertNotNil(app.attachments)
        XCTAssertNotNil(app.talent)
        XCTAssertNotNil(app.lifecycle)
        XCTAssertNotNil(app.notifications)
        XCTAssertNotNil(app.transport)
        XCTAssertNotNil(app.persistence)
    }

    func testContainerUsesInjectedProviders() throws {
        let clock = FakeClock()
        let keychain = InMemoryKeychain()
        let persistence = InMemoryPersistenceStore()
        let logger = InMemoryLogger(clock: clock)
        let app = RailCommerce(clock: clock, keychain: keychain,
                               persistence: persistence, logger: logger)

        // Exercise services so the logger sees activity on the expected categories.
        app.catalog.upsert(SKU(id: "t", kind: .ticket, title: "T", priceCents: 100))
        try app.cart.add(skuId: "t", quantity: 1)
        let address = USAddress(id: "a", recipient: "A", line1: "1 Main",
                                city: "NYC", state: .NY, zip: "10001")
        let shipping = ShippingTemplate(id: "s", name: "Std", feeCents: 0, etaDays: 1)
        let user = User(id: "u", displayName: "U", role: .customer)
        _ = try app.checkout.submit(orderId: "O-1", userId: "u", cart: app.cart,
                                    discounts: [], address: address, shipping: shipping,
                                    invoiceNotes: "", actingUser: user)

        XCTAssertFalse(logger.records(in: .checkout).isEmpty)
    }

    func testContainerSharesCartAcrossFlows() throws {
        let app = RailCommerce()
        app.catalog.upsert(SKU(id: "t", kind: .ticket, title: "T", priceCents: 100))
        try app.cart.add(skuId: "t", quantity: 3)
        // A second reference to app.cart must see the same state.
        XCTAssertEqual(app.cart.lines.count, 1)
        XCTAssertEqual(app.cart.lines.first?.quantity, 3)
    }

    func testContainerPersistsAcrossRebuild() throws {
        let persistence = InMemoryPersistenceStore()
        let keychain = InMemoryKeychain()
        let clock = FakeClock()
        let admin = User(id: "admin", displayName: "Admin", role: .administrator)

        let app1 = RailCommerce(clock: clock, keychain: keychain, persistence: persistence)
        app1.catalog.upsert(SKU(id: "t", kind: .ticket, title: "T", priceCents: 100))
        try app1.cart.add(skuId: "t", quantity: 1)
        let addr = USAddress(id: "a", recipient: "A", line1: "1 Main",
                             city: "NYC", state: .NY, zip: "10001")
        let shipping = ShippingTemplate(id: "s", name: "Std", feeCents: 0, etaDays: 1)
        _ = try app1.checkout.submit(orderId: "O-R", userId: admin.id, cart: app1.cart,
                                     discounts: [], address: addr, shipping: shipping,
                                     invoiceNotes: "", actingUser: admin)

        // New container over the same store hydrates the prior order.
        let app2 = RailCommerce(clock: clock, keychain: keychain, persistence: persistence)
        XCTAssertNotNil(app2.checkout.order("O-R", ownedBy: admin.id))
    }
}
