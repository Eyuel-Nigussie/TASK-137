import XCTest
@testable import RailCommerce

/// Regression tests for v6 audit findings, locking each fix into the test
/// suite so the defect cannot silently return:
///   - Issue 1: catalog + cart persist across restarts
///   - Issue 2: checkout pendingOrderId is reused across taps (covered in
///              CheckoutService idempotency; UI behavior is documented in
///              `CheckoutViewController`)
///   - Issue 3: seat snapshots hydrate after restart
///   - Issue 4: seat release authorization requires `actingUser`
///   - Issue 5: after-sales case messages are thread-scoped to request id
final class AuditV6ClosureTests: XCTestCase {

    // MARK: - Issue 1: Catalog + Cart persistence

    func testCatalogSurvivesRestart() {
        let store = InMemoryPersistenceStore()
        let catalog1 = Catalog(persistence: store)
        catalog1.upsert(SKU(id: "t1", kind: .ticket, title: "NE Express",
                            priceCents: 5000))
        catalog1.upsert(SKU(id: "m1", kind: .merchandise, title: "Mug",
                            priceCents: 1500))

        let catalog2 = Catalog(persistence: store)
        XCTAssertEqual(catalog2.all.map { $0.id }, ["m1", "t1"])
        XCTAssertEqual(catalog2.get("t1")?.title, "NE Express")
    }

    func testCatalogRemovePersists() {
        let store = InMemoryPersistenceStore()
        let catalog1 = Catalog(persistence: store)
        catalog1.upsert(SKU(id: "t1", kind: .ticket, title: "NE", priceCents: 5000))
        catalog1.upsert(SKU(id: "m1", kind: .merchandise, title: "Mug", priceCents: 1500))
        catalog1.remove(id: "t1")

        let catalog2 = Catalog(persistence: store)
        XCTAssertEqual(catalog2.all.map { $0.id }, ["m1"])
    }

    func testCartSurvivesRestart() throws {
        let store = InMemoryPersistenceStore()
        let catalog = Catalog([
            SKU(id: "t1", kind: .ticket, title: "T", priceCents: 1000),
            SKU(id: "m1", kind: .merchandise, title: "M", priceCents: 500)
        ], persistence: store)
        let cart1 = Cart(catalog: catalog, persistence: store)
        try cart1.add(skuId: "t1", quantity: 2)
        try cart1.add(skuId: "m1", quantity: 1)

        // "Restart" — new Cart instance reading from the same persistence.
        let cart2 = Cart(catalog: catalog, persistence: store)
        XCTAssertEqual(cart2.lines.count, 2)
        XCTAssertEqual(cart2.subtotalCents, 2000 + 500)
        XCTAssertEqual(cart2.lines.first(where: { $0.sku.id == "t1" })?.quantity, 2)
    }

    func testCartClearPersistsEmptyState() throws {
        let store = InMemoryPersistenceStore()
        let catalog = Catalog([SKU(id: "t1", kind: .ticket, title: "T", priceCents: 1000)])
        let cart1 = Cart(catalog: catalog, persistence: store)
        try cart1.add(skuId: "t1", quantity: 1)
        try cart1.clear()

        let cart2 = Cart(catalog: catalog, persistence: store)
        XCTAssertTrue(cart2.isEmpty)
    }

    // MARK: - Issue 3: Durable seat snapshots

    func testSeatSnapshotSurvivesRestart() throws {
        let clock = FakeClock()
        let store = InMemoryPersistenceStore()
        let svc1 = SeatInventoryService(clock: clock, persistence: store)
        let key = SeatKey(trainId: "NE1", date: "2024-01-02", segmentId: "NY-BOS",
                          seatClass: .economy, seatNumber: "1A")
        svc1.registerSeat(key)
        try svc1.snapshot(date: "2024-01-02")
        let salesAgent = User(id: "a1", displayName: "Agent", role: .salesAgent)
        try svc1.reserve(key, holderId: "h1", actingUser: salesAgent)
        XCTAssertEqual(svc1.state(key), .reserved)

        // "Restart" — new service against the same persistence.
        let svc2 = SeatInventoryService(clock: clock, persistence: store)
        XCTAssertTrue(svc2.availableSnapshots().contains("2024-01-02"),
                      "Snapshot must hydrate after restart")

        try svc2.rollback(to: "2024-01-02")
        XCTAssertEqual(svc2.state(key), .available,
                       "Rollback must restore state recorded in the snapshot")

        // The rollback itself must persist so a THIRD restart also sees the
        // restored available state, not the prior reserved state.
        let svc3 = SeatInventoryService(clock: clock, persistence: store)
        XCTAssertEqual(svc3.state(key), .available)
    }

    // MARK: - Issue 4: Seat release authorization

    func testReleaseRejectsForbiddenRole() throws {
        let svc = SeatInventoryService(clock: FakeClock())
        let key = SeatKey(trainId: "T1", date: "2024-06-15", segmentId: "S1",
                          seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(key)
        let agent = User(id: "a1", displayName: "Agent", role: .salesAgent)
        let editor = User(id: "e1", displayName: "Editor", role: .contentEditor)
        try svc.reserve(key, holderId: "h1", actingUser: agent)
        XCTAssertThrowsError(try svc.release(key, holderId: "h1", actingUser: editor)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }

    func testReleaseRejectsIdentityMismatchForCustomer() throws {
        let svc = SeatInventoryService(clock: FakeClock())
        let key = SeatKey(trainId: "T1", date: "2024-06-15", segmentId: "S1",
                          seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(key)
        let alice = User(id: "alice", displayName: "Alice", role: .customer)
        let bob = User(id: "bob", displayName: "Bob", role: .customer)
        try svc.reserve(key, holderId: "alice", actingUser: alice)
        XCTAssertThrowsError(try svc.release(key, holderId: "alice", actingUser: bob)) { err in
            XCTAssertEqual(err as? SeatError, .wrongHolder)
        }
        XCTAssertEqual(svc.state(key), .reserved, "Seat must remain reserved")
    }

    func testSalesAgentCanReleaseAnyHold() throws {
        let svc = SeatInventoryService(clock: FakeClock())
        let key = SeatKey(trainId: "T1", date: "2024-06-15", segmentId: "S1",
                          seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(key)
        let alice = User(id: "alice", displayName: "Alice", role: .customer)
        let agent = User(id: "a1", displayName: "Agent", role: .salesAgent)
        try svc.reserve(key, holderId: "alice", actingUser: alice)
        try svc.release(key, holderId: "alice", actingUser: agent)
        XCTAssertEqual(svc.state(key), .available)
    }

    // MARK: - Issue 5: After-sales case messaging thread

    /// Builds a directly-wired `AfterSalesService` + `MessagingService` pair
    /// without the `RailCommerce` container's ownership validator (which would
    /// require an actual Checkout submission). Mirrors production wiring: the
    /// composition root sets `afterSales.messenger = messaging`.
    private func closedLoopSetup() -> (AfterSalesService, User, User, String) {
        let clock = FakeClock()
        let messaging = MessagingService(clock: clock)
        let afterSales = AfterSalesService(clock: clock,
                                           camera: FakeCamera(granted: true),
                                           notifier: LocalNotificationBus())
        afterSales.messenger = messaging
        let customer = User(id: "alice", displayName: "Alice", role: .customer)
        let csr = User(id: "csr", displayName: "CSR", role: .customerService)
        let requestId = "R1"
        let req = AfterSalesRequest(id: requestId, orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind, createdAt: clock.now(),
                                    serviceDate: clock.now(), amountCents: 500)
        _ = try! afterSales.open(req, actingUser: customer)
        return (afterSales, customer, csr, requestId)
    }

    func testCustomerCanPostAndReadCaseThread() throws {
        let (afterSales, customer, csr, requestId) = closedLoopSetup()
        _ = try afterSales.postCaseMessage(requestId: requestId, to: "csr",
                                            body: "I still need help",
                                            actingUser: customer)
        _ = try afterSales.postCaseMessage(requestId: requestId, to: "alice",
                                            body: "Happy to help",
                                            actingUser: csr)
        let thread = try afterSales.caseMessages(requestId: requestId,
                                                  actingUser: customer)
        XCTAssertEqual(thread.count, 2)
        XCTAssertEqual(thread.first?.body, "I still need help")
        XCTAssertEqual(thread.last?.body, "Happy to help")
        XCTAssertTrue(thread.allSatisfy { $0.threadId == requestId })
    }

    func testOtherCustomerCannotReadCaseThread() throws {
        let (afterSales, _, csr, requestId) = closedLoopSetup()
        let mallory = User(id: "mallory", displayName: "Mallory", role: .customer)
        _ = try afterSales.postCaseMessage(requestId: requestId, to: "alice",
                                            body: "internal note",
                                            actingUser: csr)
        XCTAssertThrowsError(try afterSales.caseMessages(requestId: requestId,
                                                          actingUser: mallory)) { err in
            XCTAssertEqual(err as? AfterSalesError, .orderNotOwned)
        }
    }

    func testOtherCustomerCannotPostToCaseThread() throws {
        let (afterSales, _, _, requestId) = closedLoopSetup()
        let mallory = User(id: "mallory", displayName: "Mallory", role: .customer)
        XCTAssertThrowsError(try afterSales.postCaseMessage(
            requestId: requestId, to: "csr", body: "injection",
            actingUser: mallory)) { err in
            XCTAssertEqual(err as? AfterSalesError, .orderNotOwned)
        }
    }

    func testCaseMessageOnUnknownRequestThrows() {
        let afterSales = AfterSalesService(clock: FakeClock(),
                                           camera: FakeCamera(granted: true),
                                           notifier: LocalNotificationBus())
        afterSales.messenger = MessagingService(clock: FakeClock())
        let customer = User(id: "alice", displayName: "Alice", role: .customer)
        XCTAssertThrowsError(try afterSales.postCaseMessage(
            requestId: "ghost", to: "csr", body: "hi",
            actingUser: customer)) { err in
            XCTAssertEqual(err as? AfterSalesError, .notFound)
        }
    }

    /// The thread-scoped `MessagingService.messages(inThread:actingUser:)` API
    /// itself must reject non-participants of a thread with messages.
    func testMessagingThreadAPIRejectsNonParticipant() throws {
        let svc = MessagingService(clock: FakeClock())
        let alice = User(id: "alice", displayName: "Alice", role: .customer)
        let bob = User(id: "bob", displayName: "Bob", role: .customer)
        let mallory = User(id: "mallory", displayName: "Mallory", role: .customer)
        _ = try svc.enqueue(id: "m1", from: "alice", to: "bob",
                             body: "hi", actingUser: alice, threadId: "T1")
        _ = svc.drainQueue()
        // Mallory is not a participant on T1.
        XCTAssertThrowsError(try svc.messages(inThread: "T1", actingUser: mallory)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
        // But Bob (recipient) IS a participant.
        XCTAssertEqual(try svc.messages(inThread: "T1", actingUser: bob).count, 1)
    }
}
