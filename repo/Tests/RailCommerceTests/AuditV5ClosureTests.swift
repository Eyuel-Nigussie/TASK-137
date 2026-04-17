import XCTest
@testable import RailCommerce

/// Regression tests for v5 audit findings. Each test locks in the fix in
/// code so the defect cannot silently regress:
///   - Issue 2: seat reservation transactionally integrated into checkout
///   - Issue 4: `OrderSnapshot.serviceDate` anchors SLA automation correctly
///   - Issue 5: promotion pipeline reachable through checkout submit
///   - Issue 7: messaging report/block require identity binding
///   - (Issue 3 + 8 are UI-only; covered by BrowseViewController / ContentPublishingViewController changes.)
final class AuditV5ClosureTests: XCTestCase {

    private let customer = User(id: "c1", displayName: "Alice", role: .customer)
    private let salesAgent = User(id: "a1", displayName: "Sam", role: .salesAgent)

    // MARK: - Issue 2 — seat reservation in checkout

    private func checkoutKit() ->
        (CheckoutService, SeatInventoryService, Cart, USAddress, ShippingTemplate, SeatKey, SeatKey) {
        let clock = FakeClock()
        let keychain = InMemoryKeychain()
        let checkout = CheckoutService(clock: clock, keychain: keychain)
        let seats = SeatInventoryService(clock: clock)
        let catalog = Catalog([SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 5000)])
        let cart = Cart(catalog: catalog)
        try! cart.add(skuId: "t1", quantity: 1)
        let addr = USAddress(id: "a", recipient: "A", line1: "1 Main",
                             city: "NYC", state: .NY, zip: "10001")
        let ship = ShippingTemplate(id: "std", name: "Std", feeCents: 500, etaDays: 3)
        let seatA = SeatKey(trainId: "T1", date: "2024-06-15", segmentId: "NY-BOS",
                            seatClass: .economy, seatNumber: "1A")
        let seatB = SeatKey(trainId: "T1", date: "2024-06-15", segmentId: "NY-BOS",
                            seatClass: .economy, seatNumber: "1B")
        seats.registerSeat(seatA)
        seats.registerSeat(seatB)
        return (checkout, seats, cart, addr, ship, seatA, seatB)
    }

    func testCheckoutReservesAndConfirmsSeatsAtomically() throws {
        let (checkout, seats, cart, addr, ship, seatA, seatB) = checkoutKit()
        _ = try checkout.submit(orderId: "O1", userId: "c1", cart: cart, discounts: [],
                                address: addr, shipping: ship, invoiceNotes: "",
                                actingUser: customer, seats: [seatA, seatB],
                                seatInventory: seats)
        XCTAssertEqual(seats.state(seatA), .sold)
        XCTAssertEqual(seats.state(seatB), .sold)
    }

    /// If the second seat is already sold, the first seat's reservation must
    /// be rolled back — no partial sale, no oversell, and the order does not
    /// get stored.
    func testCheckoutSeatFailureRollsBackAllReservations() throws {
        let (checkout, seats, cart, addr, ship, seatA, seatB) = checkoutKit()
        // Pre-sell seatB so the checkout's seatB step fails.
        try seats.reserve(seatB, holderId: "other", actingUser: salesAgent)
        try seats.confirm(seatB, holderId: "other", actingUser: salesAgent)
        XCTAssertEqual(seats.state(seatB), .sold)

        XCTAssertThrowsError(try checkout.submit(orderId: "O1", userId: "c1", cart: cart,
                                                  discounts: [], address: addr, shipping: ship,
                                                  invoiceNotes: "", actingUser: customer,
                                                  seats: [seatA, seatB], seatInventory: seats))
        // seatA must be rolled back to available; seatB remains sold by the
        // original owner; the order must NOT be persisted.
        XCTAssertEqual(seats.state(seatA), .available)
        XCTAssertEqual(seats.state(seatB), .sold)
        XCTAssertNil(checkout.order("O1", ownedBy: "c1"))
    }

    func testCheckoutWithoutSeatsWorksAsBefore() throws {
        let (checkout, _, cart, addr, ship, _, _) = checkoutKit()
        let snap = try checkout.submit(orderId: "O1", userId: "c1", cart: cart,
                                        discounts: [], address: addr, shipping: ship,
                                        invoiceNotes: "", actingUser: customer)
        XCTAssertEqual(snap.orderId, "O1")
    }

    // MARK: - Issue 4 — OrderSnapshot.serviceDate

    func testOrderSnapshotCarriesExplicitServiceDate() throws {
        let (checkout, _, cart, addr, ship, _, _) = checkoutKit()
        let serviceDate = Date(timeIntervalSince1970: 2_000_000_000)
        let snap = try checkout.submit(orderId: "O1", userId: "c1", cart: cart,
                                        discounts: [], address: addr, shipping: ship,
                                        invoiceNotes: "", actingUser: customer,
                                        serviceDate: serviceDate)
        XCTAssertEqual(snap.serviceDate, serviceDate,
                       "serviceDate must be preserved as passed; not overwritten with createdAt")
        XCTAssertNotEqual(snap.serviceDate, snap.createdAt)
    }

    func testOrderSnapshotServiceDateDefaultsToCreatedAt() throws {
        let (checkout, _, cart, addr, ship, _, _) = checkoutKit()
        let snap = try checkout.submit(orderId: "O1", userId: "c1", cart: cart,
                                        discounts: [], address: addr, shipping: ship,
                                        invoiceNotes: "", actingUser: customer)
        XCTAssertEqual(snap.serviceDate, snap.createdAt,
                       "serviceDate must default to createdAt for merchandise-only orders")
    }

    // MARK: - Issue 5 — promotions reachable from checkout

    func testCheckoutAppliesPromoCodesAtSubmit() throws {
        let (checkout, _, cart, addr, ship, _, _) = checkoutKit()
        let discounts = [Discount(code: "PCT10", kind: .percentOff, magnitude: 10, priority: 1)]
        let snap = try checkout.submit(orderId: "O1", userId: "c1", cart: cart,
                                        discounts: discounts, address: addr, shipping: ship,
                                        invoiceNotes: "", actingUser: customer)
        XCTAssertEqual(snap.promotion.acceptedCodes, ["PCT10"])
        XCTAssertGreaterThan(snap.promotion.totalDiscountCents, 0)
    }

    // MARK: - Issue 7 — messaging report/block identity binding

    private let alice = User(id: "alice", displayName: "Alice", role: .customer)
    private let bob = User(id: "bob", displayName: "Bob", role: .customer)
    private let csr = User(id: "csr", displayName: "CSR", role: .customerService)

    func testBlockRejectsForgedIdentity() {
        let svc = MessagingService(clock: FakeClock())
        // Bob cannot insert a block "X → alice" as if he were alice.
        XCTAssertThrowsError(try svc.block(from: "x", to: "alice", actingUser: bob)) { err in
            XCTAssertEqual(err as? MessagingError, .senderIdentityMismatch)
        }
    }

    func testUnblockRejectsForgedIdentity() {
        let svc = MessagingService(clock: FakeClock())
        XCTAssertThrowsError(try svc.unblock(from: "x", to: "alice", actingUser: bob)) { err in
            XCTAssertEqual(err as? MessagingError, .senderIdentityMismatch)
        }
    }

    func testReportMessageRejectsForgedReporter() throws {
        let svc = MessagingService(clock: FakeClock())
        _ = try svc.enqueue(id: "m1", from: "alice", to: "bob", body: "hi", actingUser: alice)
        _ = svc.drainQueue()
        XCTAssertThrowsError(try svc.reportMessage("m1", reportedBy: "alice",
                                                    reason: "x", actingUser: bob)) { err in
            XCTAssertEqual(err as? MessagingError, .senderIdentityMismatch)
        }
    }

    func testReportUserRejectsForgedReporter() {
        let svc = MessagingService(clock: FakeClock())
        XCTAssertThrowsError(try svc.reportUser("attacker", reportedBy: "alice",
                                                reason: "x", actingUser: bob)) { err in
            XCTAssertEqual(err as? MessagingError, .senderIdentityMismatch)
        }
    }

    func testCSRMayReportOnBehalfOfAnyUser() throws {
        let svc = MessagingService(clock: FakeClock())
        try svc.reportUser("attacker", reportedBy: "alice", reason: "x", actingUser: csr)
        XCTAssertTrue(svc.isBlocked(from: "attacker", to: "alice"))
    }
}
