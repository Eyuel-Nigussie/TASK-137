import XCTest
@testable import RailCommerce

/// Closure tests for the remaining v3 static-audit gaps:
/// - boundary conditions on auto-approve (< $25 edge) and auto-reject (14-day edge)
/// - checkout snapshot line-level explanation persistence across hydration
/// - persistence + idempotency combined regression
/// - transport send-failure / retry integration
/// - targeted abuse tests for less-common mutators (seat release / confirm with spoofed holder)
///
/// These keep the suite from going green while high-impact defects regress.
final class AuditClosureTests: XCTestCase {

    // MARK: - After-sales boundary: $25.00 auto-approve edge

    /// Exactly $25.00 is NOT under-threshold — auto-approve must NOT fire.
    /// The rule is "under $25", so 2500¢ is a cliff, not a cutoff.
    func testAutoApproveNotAppliedAtExactly2500Cents() throws {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_704_103_200))
        let svc = AfterSalesService(clock: clock, camera: FakeCamera(granted: true),
                                    notifier: LocalNotificationBus())
        let customer = User(id: "c1", displayName: "C", role: .customer)
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind, createdAt: clock.now(),
                                    serviceDate: clock.now(),
                                    amountCents: AfterSalesService.autoApproveUnderCents)
        try svc.open(req, actingUser: customer)
        clock.advance(by: 49 * 3600)
        _ = svc.runAutomation()
        XCTAssertNotEqual(svc.get("R1")?.status, .autoApproved,
                          "Exactly $25.00 must not auto-approve — rule is strictly under")
    }

    /// $24.99 IS under-threshold — auto-approve must fire.
    func testAutoApproveAppliedJustUnder2500Cents() throws {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_704_103_200))
        let svc = AfterSalesService(clock: clock, camera: FakeCamera(granted: true),
                                    notifier: LocalNotificationBus())
        let customer = User(id: "c1", displayName: "C", role: .customer)
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind, createdAt: clock.now(),
                                    serviceDate: clock.now(),
                                    amountCents: AfterSalesService.autoApproveUnderCents - 1)
        try svc.open(req, actingUser: customer)
        clock.advance(by: 49 * 3600)
        _ = svc.runAutomation()
        XCTAssertEqual(svc.get("R1")?.status, .autoApproved)
    }

    // MARK: - After-sales boundary: 14-day auto-reject edge

    /// 13 days past service date must NOT auto-reject — threshold is "14+ days past".
    func testAutoRejectNotAppliedAt13DaysPast() throws {
        let base = Date(timeIntervalSince1970: 1_704_103_200)
        let clock = FakeClock(base)
        let svc = AfterSalesService(clock: clock, camera: FakeCamera(granted: true),
                                    notifier: LocalNotificationBus())
        let customer = User(id: "c1", displayName: "C", role: .customer)
        // serviceDate = 13 days BEFORE createdAt
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind, createdAt: base,
                                    serviceDate: base.addingTimeInterval(-13 * 86_400),
                                    amountCents: 5_000)
        try svc.open(req, actingUser: customer)
        _ = svc.runAutomation()
        XCTAssertNotEqual(svc.get("R1")?.status, .autoRejected)
    }

    /// Exactly 14 days past service date MUST auto-reject.
    func testAutoRejectAppliedAtExactly14DaysPast() throws {
        let base = Date(timeIntervalSince1970: 1_704_103_200)
        let clock = FakeClock(base)
        let svc = AfterSalesService(clock: clock, camera: FakeCamera(granted: true),
                                    notifier: LocalNotificationBus())
        let customer = User(id: "c1", displayName: "C", role: .customer)
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind, createdAt: base,
                                    serviceDate: base.addingTimeInterval(-14 * 86_400),
                                    amountCents: 5_000)
        try svc.open(req, actingUser: customer)
        _ = svc.runAutomation()
        XCTAssertEqual(svc.get("R1")?.status, .autoRejected)
    }

    // MARK: - Checkout snapshot line-level explanation persistence

    /// Round-trips an order snapshot through the persistence store and asserts the
    /// line-level promotion explanations survive hydration (codes, cents, skus).
    func testOrderSnapshotLineExplanationsSurvivePersistenceHydration() throws {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_704_103_200))
        let keychain = InMemoryKeychain()
        let store = InMemoryPersistenceStore()
        let service = CheckoutService(clock: clock, keychain: keychain, persistence: store)
        let catalog = Catalog([
            SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 5_000),
            SKU(id: "m1", kind: .merchandise, title: "M1", priceCents: 1_500)
        ])
        let cart = Cart(catalog: catalog)
        try cart.add(skuId: "t1", quantity: 1)
        try cart.add(skuId: "m1", quantity: 1)
        let address = USAddress(id: "a1", recipient: "A", line1: "1 Main",
                                city: "NYC", state: .NY, zip: "10001")
        let shipping = ShippingTemplate(id: "std", name: "Standard", feeCents: 500, etaDays: 3)
        let customer = User(id: "c1", displayName: "Alice", role: .customer)
        let discounts = [
            Discount(code: "PCT10", kind: .percentOff, magnitude: 10, priority: 1),
            Discount(code: "AMT200", kind: .amountOff, magnitude: 200, priority: 2)
        ]
        let snap = try service.submit(orderId: "O1", userId: "c1", cart: cart,
                                      discounts: discounts, address: address,
                                      shipping: shipping, invoiceNotes: "",
                                      actingUser: customer)
        XCTAssertFalse(snap.promotion.lineExplanations.isEmpty)

        // Rebuild a fresh service from the same store — must re-hydrate the snapshot
        // including every line's applied-codes breakdown.
        let rebuilt = CheckoutService(clock: clock, keychain: keychain, persistence: store)
        guard let hydrated = rebuilt.order("O1", ownedBy: "c1") else {
            XCTFail("snapshot did not hydrate"); return
        }
        XCTAssertEqual(hydrated.promotion.acceptedCodes, snap.promotion.acceptedCodes)
        XCTAssertEqual(hydrated.promotion.totalDiscountCents, snap.promotion.totalDiscountCents)
        XCTAssertEqual(hydrated.promotion.lineExplanations.count, snap.promotion.lineExplanations.count)
        for (h, s) in zip(hydrated.promotion.lineExplanations, snap.promotion.lineExplanations) {
            XCTAssertEqual(h.skuId, s.skuId)
            XCTAssertEqual(h.originalCents, s.originalCents)
            XCTAssertEqual(h.discountedCents, s.discountedCents)
            XCTAssertEqual(h.appliedCodes, s.appliedCodes)
        }
    }

    // MARK: - Persistence + idempotency combined regression

    /// After a successful submit, the snapshot lives in persistence. A fresh
    /// service instance that hydrates the snapshot MUST still reject a duplicate
    /// `submit` with the same orderId — idempotency is orderStore-wide, not just
    /// in-memory lockout.
    func testIdempotencySurvivesRestart() throws {
        let keychain = InMemoryKeychain()
        let store = InMemoryPersistenceStore()
        let service1 = CheckoutService(clock: FakeClock(), keychain: keychain, persistence: store)
        let catalog = Catalog([SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 1_000)])
        let cart = Cart(catalog: catalog)
        try cart.add(skuId: "t1", quantity: 1)
        let address = USAddress(id: "a", recipient: "A", line1: "1 Main",
                                city: "NYC", state: .NY, zip: "10001")
        let shipping = ShippingTemplate(id: "std", name: "S", feeCents: 0, etaDays: 1)
        let customer = User(id: "c1", displayName: "C", role: .customer)
        _ = try service1.submit(orderId: "SAME", userId: "c1", cart: cart, discounts: [],
                                address: address, shipping: shipping, invoiceNotes: "",
                                actingUser: customer)

        // Simulate app restart: new clock (past the 10s in-memory window),
        // new service, same store.
        let service2 = CheckoutService(clock: FakeClock(), keychain: keychain, persistence: store)
        XCTAssertThrowsError(try service2.submit(orderId: "SAME", userId: "c1", cart: cart,
                                                 discounts: [], address: address,
                                                 shipping: shipping, invoiceNotes: "",
                                                 actingUser: customer)) { err in
            XCTAssertEqual(err as? CheckoutError, .duplicateSubmission,
                           "Idempotency must survive process restart via persisted snapshot")
        }
    }

    // MARK: - Messaging transport send-failure / retry integration

    /// A transport that throws on send must NOT cause the messaging service to
    /// lose the message — it must stay in the queue for a later drain cycle.
    func testMessagingRequeuesWhenTransportFails() throws {
        let clock = FakeClock()
        let transport = FailingTransport()
        let csr = User(id: "csr", displayName: "CSR", role: .customerService)
        let svc = MessagingService(clock: clock, transport: transport)

        _ = try svc.enqueue(id: "m1", from: "csr", to: "agent", body: "hi", actingUser: csr)
        XCTAssertEqual(svc.queue.count, 1)

        // First drain: transport is failing, message must remain queued.
        transport.mode = .throwError
        let firstDrain = svc.drainQueue()
        XCTAssertTrue(firstDrain.isEmpty, "Failed dispatch must not be counted as delivered")
        XCTAssertEqual(svc.queue.count, 1, "Message must remain in queue after transport failure")
        XCTAssertTrue(svc.deliveredMessages.isEmpty)

        // Second drain: transport returns no peers (still queued, offline).
        transport.mode = .noPeers
        let secondDrain = svc.drainQueue()
        XCTAssertTrue(secondDrain.isEmpty)
        XCTAssertEqual(svc.queue.count, 1)

        // Third drain: transport succeeds — message finally delivered.
        transport.mode = .ok
        let thirdDrain = svc.drainQueue()
        XCTAssertEqual(thirdDrain.count, 1)
        XCTAssertTrue(svc.queue.isEmpty)
        XCTAssertEqual(svc.deliveredMessages.count, 1)
    }

    // MARK: - Abuse tests for less-common mutators

    /// Holder identity must be enforced on confirm — a different holder cannot
    /// convert another user's reservation into a sale, even with a valid role.
    func testSeatConfirmRejectsDifferentHolder() throws {
        let svc = SeatInventoryService(clock: FakeClock())
        let key = SeatKey(trainId: "T1", date: "2024-01-02", segmentId: "S1",
                          seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(key)
        let alice = User(id: "alice", displayName: "Alice", role: .customer)
        let mallory = User(id: "mallory", displayName: "Mallory", role: .customer)
        try svc.reserve(key, holderId: alice.id, actingUser: alice)
        XCTAssertThrowsError(try svc.confirm(key, holderId: mallory.id, actingUser: mallory)) { err in
            XCTAssertEqual(err as? SeatError, .wrongHolder,
                           "Confirm must reject a different holder even with a valid role")
        }
        XCTAssertEqual(svc.state(key), .reserved)
    }

    /// Release path abuse: wrong holder cannot cancel another user's reservation.
    func testSeatReleaseRejectsDifferentHolder() throws {
        let svc = SeatInventoryService(clock: FakeClock())
        let key = SeatKey(trainId: "T1", date: "2024-01-02", segmentId: "S1",
                          seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(key)
        let alice = User(id: "alice", displayName: "Alice", role: .customer)
        try svc.reserve(key, holderId: alice.id, actingUser: alice)
        let mallory = User(id: "mallory", displayName: "Mallory", role: .customer)
        XCTAssertThrowsError(try svc.release(key, holderId: "mallory",
                                             actingUser: mallory)) { err in
            XCTAssertEqual(err as? SeatError, .wrongHolder)
        }
        XCTAssertEqual(svc.state(key), .reserved, "Seat must remain held by Alice")
    }

    /// Admin-style privileged roles without `.purchase`/`.processTransaction` still
    /// hit the auth guard for seat reservation — role matrix is authoritative.
    func testSeatReserveForbiddenForContentReviewer() {
        let svc = SeatInventoryService(clock: FakeClock())
        let key = SeatKey(trainId: "T1", date: "2024-01-02", segmentId: "S1",
                          seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(key)
        let reviewer = User(id: "r", displayName: "R", role: .contentReviewer)
        XCTAssertThrowsError(try svc.reserve(key, holderId: reviewer.id, actingUser: reviewer)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }

    /// Messaging sender identity must be enforced even when the target user does
    /// not exist — the check is on the acting user, not the target.
    func testMessagingEnforceSenderIdentityAgainstSpoofedFrom() throws {
        let svc = MessagingService(clock: FakeClock())
        let alice = User(id: "alice", displayName: "Alice", role: .customer)
        XCTAssertThrowsError(try svc.enqueue(id: "m1", from: "bob", to: "any",
                                              body: "hi", actingUser: alice)) { err in
            XCTAssertEqual(err as? MessagingError, .senderIdentityMismatch)
        }
    }
}

// MARK: - Test doubles

/// Controllable transport double for failure/retry scenarios.
private final class FailingTransport: MessageTransport {
    enum Mode { case throwError, noPeers, ok }
    var mode: Mode = .ok
    private var handlers: [(Message) -> Void] = []

    func send(_ message: Message) throws -> [String] {
        switch mode {
        case .throwError: throw TransportError.notStarted
        case .noPeers: return []
        case .ok: return [message.toUserId]
        }
    }

    func onReceive(_ handler: @escaping (Message) -> Void) { handlers.append(handler) }
    func start(asPeer peerId: String) throws {}
    func stop() {}
    var connectedPeers: [String] { [] }
}
