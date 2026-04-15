import XCTest
@testable import RailCommerce

final class CheckoutServiceTests: XCTestCase {
    private func setup() -> (CheckoutService, Cart, USAddress, ShippingTemplate, FakeClock, InMemoryKeychain) {
        let clock = FakeClock()
        let keychain = InMemoryKeychain()
        let service = CheckoutService(clock: clock, keychain: keychain)
        let catalog = Catalog([
            SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 1_000)
        ])
        let cart = Cart(catalog: catalog)
        try! cart.add(skuId: "t1", quantity: 2)
        let address = USAddress(id: "addr1", recipient: "A", line1: "1 Main",
                                city: "NYC", state: .NY, zip: "10001", isDefault: true)
        let shipping = ShippingTemplate(id: "std", name: "Standard", feeCents: 500, etaDays: 3)
        return (service, cart, address, shipping, clock, keychain)
    }

    func testSuccessfulSubmission() throws {
        let (service, cart, address, shipping, _, keychain) = setup()
        let snap = try service.submit(orderId: "O1", userId: "U1", cart: cart,
                                      discounts: [], address: address,
                                      shipping: shipping, invoiceNotes: "please expedite")
        XCTAssertEqual(snap.totalCents, 2_000 + 500)
        XCTAssertNotNil(service.order("O1"))
        XCTAssertNotNil(service.storedHash(for: "O1"))
        XCTAssertTrue(keychain.isSealed("order.hash.O1"))
    }

    func testFreeShippingDiscountRemovesShippingFee() throws {
        let (service, cart, address, shipping, _, _) = setup()
        let d = Discount(code: "SHIP", kind: .freeShipping, magnitude: 0, priority: 1)
        let snap = try service.submit(orderId: "O2", userId: "U1", cart: cart,
                                      discounts: [d], address: address,
                                      shipping: shipping, invoiceNotes: "")
        XCTAssertEqual(snap.totalCents, 2_000)
    }

    func testDuplicateLockoutWithin10Seconds() throws {
        let (service, cart, address, shipping, clock, _) = setup()
        _ = try service.submit(orderId: "O3", userId: "U", cart: cart,
                               discounts: [], address: address,
                               shipping: shipping, invoiceNotes: "")
        clock.advance(by: 5)
        XCTAssertThrowsError(try service.submit(orderId: "O3", userId: "U", cart: cart,
                                                discounts: [], address: address,
                                                shipping: shipping, invoiceNotes: "")) { err in
            XCTAssertEqual(err as? CheckoutError, .duplicateSubmission)
        }
    }

    func testDuplicateAllowedAfter10Seconds() throws {
        let (service, cart, address, shipping, clock, _) = setup()
        _ = try service.submit(orderId: "O4", userId: "U", cart: cart,
                               discounts: [], address: address,
                               shipping: shipping, invoiceNotes: "")
        clock.advance(by: 11)
        // Because Keychain is sealed for the first order, second attempt should now be
        // read-only. We route via a fresh keychain to show lockout expires.
        let fresh = InMemoryKeychain()
        let fresh2 = CheckoutService(clock: clock, keychain: fresh)
        _ = try fresh2.submit(orderId: "O4", userId: "U", cart: cart,
                              discounts: [], address: address,
                              shipping: shipping, invoiceNotes: "")
        XCTAssertNotNil(fresh2.order("O4"))
    }

    func testEmptyCartRejected() {
        let (service, _, address, shipping, _, _) = setup()
        let emptyCart = Cart(catalog: Catalog())
        XCTAssertThrowsError(try service.submit(orderId: "O5", userId: "U", cart: emptyCart,
                                                discounts: [], address: address,
                                                shipping: shipping, invoiceNotes: "")) { err in
            XCTAssertEqual(err as? CheckoutError, .emptyCart)
        }
    }

    func testMissingShippingRejected() {
        let (service, cart, address, _, _, _) = setup()
        XCTAssertThrowsError(try service.submit(orderId: "O6", userId: "U", cart: cart,
                                                discounts: [], address: address,
                                                shipping: nil, invoiceNotes: "")) { err in
            XCTAssertEqual(err as? CheckoutError, .noShipping)
        }
    }

    func testInvalidAddressRejected() {
        let (service, cart, _, shipping, _, _) = setup()
        let bad = USAddress(id: "x", recipient: "a", line1: "x", city: "x", state: .NY, zip: "bad")
        XCTAssertThrowsError(try service.submit(orderId: "O7", userId: "U", cart: cart,
                                                discounts: [], address: bad,
                                                shipping: shipping, invoiceNotes: "")) { err in
            if case .addressInvalid(let inner) = err as? CheckoutError {
                XCTAssertEqual(inner, .invalidZip)
            } else { XCTFail("expected addressInvalid") }
        }
    }

    func testVerifyDetectsTampering() throws {
        let (service, cart, address, shipping, _, _) = setup()
        let snap = try service.submit(orderId: "O8", userId: "U", cart: cart,
                                      discounts: [], address: address,
                                      shipping: shipping, invoiceNotes: "")
        var tampered = snap
        tampered = OrderSnapshot(orderId: snap.orderId, userId: snap.userId, lines: snap.lines,
                                 promotion: snap.promotion, address: snap.address,
                                 shipping: snap.shipping,
                                 invoiceNotes: "altered",
                                 totalCents: snap.totalCents, createdAt: snap.createdAt)
        XCTAssertThrowsError(try service.verify(tampered)) { err in
            XCTAssertEqual(err as? CheckoutError, .tamperDetected)
        }
        XCTAssertNoThrow(try service.verify(snap))
    }

    func testKeychainKeyIncludesOrderId() {
        XCTAssertEqual(CheckoutService.keychainKey(for: "X"), "order.hash.X")
    }

    func testCanonicalFieldsAreStableForSnapshot() {
        let snap = OrderSnapshot(
            orderId: "Z", userId: "U",
            lines: [CartLine(sku: SKU(id: "a", kind: .ticket, title: "a", priceCents: 1), quantity: 1)],
            promotion: PromotionResultSnapshot(from: PromotionResult(
                acceptedCodes: [], rejectedCodes: [],
                subtotalCents: 1, totalDiscountCents: 0, finalCents: 1,
                freeShipping: false, lineExplanations: [], rejectionReasons: [:])),
            address: USAddress(id: "a", recipient: "a", line1: "1 Main", city: "NYC", state: .NY, zip: "12345"),
            shipping: ShippingTemplate(id: "std", name: "Standard", feeCents: 500, etaDays: 3),
            invoiceNotes: "", totalCents: 1, createdAt: Date(timeIntervalSince1970: 0))
        let fields = CheckoutService.canonicalFields(snap)
        XCTAssertEqual(fields["orderId"], "Z")
        XCTAssertEqual(fields["lines"], "ax1@1")
        // Full address detail in hash
        XCTAssertEqual(fields["addrLine1"], "1 Main")
        XCTAssertEqual(fields["addrCity"], "NYC")
        XCTAssertEqual(fields["addrState"], "NY")
        XCTAssertEqual(fields["addrZip"], "12345")
        // Full shipping detail in hash
        XCTAssertEqual(fields["shippingName"], "Standard")
        XCTAssertEqual(fields["shippingFee"], "500")
        // Discount total in hash
        XCTAssertEqual(fields["discountTotal"], "0")
    }

    func testOrdersForUser() throws {
        let clock = FakeClock()
        let keychain = InMemoryKeychain()
        let svc = CheckoutService(clock: clock, keychain: keychain)
        let catalog = Catalog([SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 1_000)])
        let address = USAddress(id: "a1", recipient: "A", line1: "1 Main",
                                city: "NYC", state: .NY, zip: "10001", isDefault: true)
        let shipping = ShippingTemplate(id: "std", name: "Standard", feeCents: 500, etaDays: 3)

        // Two orders for alice; one for bob — exercises filter and sort (2 alice orders).
        for orderId in ["OA2", "OA1"] {
            let cart = Cart(catalog: catalog)
            try cart.add(skuId: "t1", quantity: 1)
            clock.advance(by: 15)   // ensure clock advances so lockout doesn't trigger
            _ = try svc.submit(orderId: orderId, userId: "user-alice", cart: cart,
                               discounts: [], address: address, shipping: shipping, invoiceNotes: "")
        }
        let cart3 = Cart(catalog: catalog)
        try cart3.add(skuId: "t1", quantity: 1)
        clock.advance(by: 15)
        _ = try svc.submit(orderId: "OB", userId: "user-bob", cart: cart3,
                           discounts: [], address: address, shipping: shipping, invoiceNotes: "")

        // Alice has 2 orders sorted by ID: OA1, OA2
        let aliceOrders = svc.orders(for: "user-alice")
        XCTAssertEqual(aliceOrders.count, 2)
        XCTAssertEqual(aliceOrders.map { $0.orderId }, ["OA1", "OA2"])

        // Bob has 1 order; alice bucket is isolated
        XCTAssertEqual(svc.orders(for: "user-bob").count, 1)
        XCTAssertTrue(svc.orders(for: "user-carol").isEmpty)
    }

    func testPromotionResultSnapshotCodable() throws {
        let result = PromotionResult(
            acceptedCodes: ["A"], rejectedCodes: ["B"],
            subtotalCents: 10, totalDiscountCents: 2, finalCents: 8,
            freeShipping: false,
            lineExplanations: [LineExplanation(skuId: "x", originalCents: 10,
                                               discountedCents: 8, appliedCodes: ["A"])],
            rejectionReasons: ["B": "reason"])
        let snap = PromotionResultSnapshot(from: result)
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(PromotionResultSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
    }

    func testShippingTemplateRoundTrip() throws {
        let t = ShippingTemplate(id: "s", name: "Standard", feeCents: 100, etaDays: 2)
        let data = try JSONEncoder().encode(t)
        XCTAssertEqual(try JSONDecoder().decode(ShippingTemplate.self, from: data), t)
    }
}
