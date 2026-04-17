import XCTest
@testable import RailCommerce

/// Closure tests for audit report-2. Each test pins one finding to a
/// reproducible negative case plus a positive case, so a future regression
/// fails loudly instead of silently reopening the security defect.
final class AuditReport2ClosureTests: XCTestCase {

    private let customer = User(id: "c1", displayName: "C", role: .customer)
    private let csr = User(id: "csr1", displayName: "CSR", role: .customerService)
    private let agent = User(id: "a1", displayName: "Agent", role: .salesAgent)
    private let admin = User(id: "admin", displayName: "Admin", role: .administrator)
    private let editor = User(id: "ed", displayName: "Ed", role: .contentEditor)

    // MARK: - Finding #2: SeatInventory admin mutators require .manageInventory

    /// Customers have only `.purchase`; they must not be able to register
    /// baseline seats (the admin mutator is authentication-bound).
    func testCustomerCannotRegisterSeat() {
        let svc = SeatInventoryService(clock: FakeClock())
        let seat = SeatKey(trainId: "T", date: "2024-01-01", segmentId: "A-B",
                           seatClass: .economy, seatNumber: "1A")
        XCTAssertThrowsError(try svc.registerSeat(seat, actingUser: customer)) { err in
            if case .forbidden(required: let perm) = err as? AuthorizationError {
                XCTAssertEqual(perm, .manageInventory)
            } else {
                XCTFail("Expected AuthorizationError.forbidden(.manageInventory)")
            }
        }
    }

    /// `.salesAgent` holds `.manageInventory`; admin inherits it. Both must
    /// succeed so the inventory-admin workflow is still reachable.
    func testSalesAgentAndAdminCanRegisterSeat() throws {
        let svc = SeatInventoryService(clock: FakeClock())
        let seat = SeatKey(trainId: "T", date: "2024-01-01", segmentId: "A-B",
                           seatClass: .economy, seatNumber: "1A")
        XCTAssertNoThrow(try svc.registerSeat(seat, actingUser: agent))
        let seat2 = SeatKey(trainId: "T", date: "2024-01-01", segmentId: "A-B",
                            seatClass: .economy, seatNumber: "2A")
        XCTAssertNoThrow(try svc.registerSeat(seat2, actingUser: admin))
    }

    func testCustomerCannotSnapshotOrRollback() throws {
        let svc = SeatInventoryService(clock: FakeClock())
        XCTAssertThrowsError(try svc.snapshot(date: "2024-01-01", actingUser: customer)) { err in
            if case .forbidden = err as? AuthorizationError {} else { XCTFail() }
        }
        XCTAssertThrowsError(try svc.rollback(to: "2024-01-01", actingUser: customer)) { err in
            if case .forbidden = err as? AuthorizationError {} else { XCTFail() }
        }
    }

    func testSnapshotAndRollbackAllowedForSalesAgent() throws {
        let svc = SeatInventoryService(clock: FakeClock())
        let seat = SeatKey(trainId: "T", date: "2024-01-01", segmentId: "A-B",
                           seatClass: .economy, seatNumber: "1A")
        try svc.registerSeat(seat, actingUser: agent)
        try svc.snapshot(date: "2024-01-01", actingUser: agent)
        XCTAssertNoThrow(try svc.rollback(to: "2024-01-01", actingUser: agent))
    }

    // MARK: - Finding #3: AfterSales raw reads gated

    private func seededAfterSales() throws -> (AfterSalesService, AfterSalesRequest) {
        let svc = AfterSalesService(clock: FakeClock(),
                                    camera: FakeCamera(granted: true),
                                    notifier: LocalNotificationBus())
        let req = AfterSalesRequest(id: "R1", orderId: "O1",
                                    kind: .refundOnly, reason: .changedMind,
                                    createdAt: Date(), serviceDate: Date(),
                                    amountCents: 500)
        try svc.open(req, actingUser: customer)
        return (svc, req)
    }

    /// Bare `get(_:actingUser:)` must reject cross-user reads from a customer
    /// who did not create the request. CSR / admin must pass through.
    func testAfterSalesGetRequiresOwnershipOrPrivilege() throws {
        let (svc, req) = try seededAfterSales()
        let otherCustomer = User(id: "c2", displayName: "Other", role: .customer)
        XCTAssertThrowsError(try svc.get(req.id, actingUser: otherCustomer)) { err in
            if case .forbidden = err as? AuthorizationError {} else { XCTFail() }
        }
        XCTAssertNoThrow(try svc.get(req.id, actingUser: customer))
        XCTAssertNoThrow(try svc.get(req.id, actingUser: csr))
    }

    func testAfterSalesRequestsForOrderFiltersByCaller() throws {
        let (svc, _) = try seededAfterSales()
        let otherCustomer = User(id: "c2", displayName: "Other", role: .customer)
        let mine = try svc.requests(for: "O1", actingUser: customer)
        XCTAssertEqual(mine.count, 1, "customer must see their own request")
        let theirs = try svc.requests(for: "O1", actingUser: otherCustomer)
        XCTAssertTrue(theirs.isEmpty,
                      "non-owning customer must see no requests for this order")
        let csrView = try svc.requests(for: "O1", actingUser: csr)
        XCTAssertEqual(csrView.count, 1, "CSR must see the request")
    }

    // MARK: - Finding #4: Tamper hash covers every snapshot field

    private func makeSnapshot() -> OrderSnapshot {
        OrderSnapshot(
            orderId: "O", userId: "c1",
            lines: [CartLine(sku: SKU(id: "t", kind: .ticket, title: "T",
                                      priceCents: 100), quantity: 1, notes: "gift")],
            promotion: PromotionResultSnapshot(from: PromotionResult(
                acceptedCodes: ["A"], rejectedCodes: ["B"],
                subtotalCents: 100, totalDiscountCents: 5, finalCents: 95,
                freeShipping: true,
                lineExplanations: [LineExplanation(
                    skuId: "t", originalCents: 100, discountedCents: 95,
                    appliedCodes: ["A"])],
                rejectionReasons: ["B": "stack"])),
            address: USAddress(id: "a", recipient: "R", line1: "1",
                               line2: "Apt 2", city: "NYC", state: .NY,
                               zip: "10001", isDefault: true),
            shipping: ShippingTemplate(id: "std", name: "Std", feeCents: 500, etaDays: 3),
            invoiceNotes: "note", totalCents: 95,
            createdAt: Date(timeIntervalSince1970: 1_000),
            serviceDate: Date(timeIntervalSince1970: 2_000))
    }

    /// Every meaningful field must contribute to the tamper hash so any
    /// post-submit mutation is detected.
    func testTamperHashCoversServiceDate() {
        let base = makeSnapshot()
        var mutated = base
        mutated = OrderSnapshot(orderId: base.orderId, userId: base.userId,
                                lines: base.lines, promotion: base.promotion,
                                address: base.address, shipping: base.shipping,
                                invoiceNotes: base.invoiceNotes,
                                totalCents: base.totalCents,
                                createdAt: base.createdAt,
                                serviceDate: base.serviceDate.addingTimeInterval(3_600))
        XCTAssertNotEqual(CheckoutService.canonicalFields(base)["serviceDate"],
                          CheckoutService.canonicalFields(mutated)["serviceDate"])
    }

    func testTamperHashCoversPromotionLineDetail() {
        let base = makeSnapshot()
        // Build a mutated variant with a different discountedCents on the line.
        let mutatedLines = [LineExplanation(
            skuId: "t", originalCents: 100, discountedCents: 90, appliedCodes: ["A"])]
        let mutated = OrderSnapshot(
            orderId: base.orderId, userId: base.userId, lines: base.lines,
            promotion: PromotionResultSnapshot(from: PromotionResult(
                acceptedCodes: ["A"], rejectedCodes: ["B"],
                subtotalCents: 100, totalDiscountCents: 5, finalCents: 95,
                freeShipping: true,
                lineExplanations: mutatedLines,
                rejectionReasons: ["B": "stack"])),
            address: base.address, shipping: base.shipping,
            invoiceNotes: base.invoiceNotes, totalCents: base.totalCents,
            createdAt: base.createdAt, serviceDate: base.serviceDate)
        XCTAssertNotEqual(CheckoutService.canonicalFields(base)["promoLines"],
                          CheckoutService.canonicalFields(mutated)["promoLines"])
    }

    func testTamperHashCoversAddressRecipient() {
        let base = makeSnapshot()
        let mutatedAddr = USAddress(id: base.address.id, recipient: "OtherName",
                                    line1: base.address.line1, line2: base.address.line2,
                                    city: base.address.city, state: base.address.state,
                                    zip: base.address.zip, isDefault: base.address.isDefault)
        let mutated = OrderSnapshot(orderId: base.orderId, userId: base.userId,
                                    lines: base.lines, promotion: base.promotion,
                                    address: mutatedAddr, shipping: base.shipping,
                                    invoiceNotes: base.invoiceNotes,
                                    totalCents: base.totalCents,
                                    createdAt: base.createdAt,
                                    serviceDate: base.serviceDate)
        XCTAssertNotEqual(CheckoutService.canonicalFields(base)["addrRecipient"],
                          CheckoutService.canonicalFields(mutated)["addrRecipient"])
    }

    // MARK: - Finding #5: Checkout persist failure does not leave side effects

    /// When `persist` throws, no keychain hash is sealed and no orderStore /
    /// duplicate-lockout entry is written. A caller seeing
    /// `.persistenceFailed` must be free to retry the same orderId.
    func testCheckoutPersistFailureLeavesNoSideEffects() throws {
        final class FailingStore: PersistenceStore {
            func save(key: String, data: Data) throws {
                throw PersistenceError.encodingFailed
            }
            func load(key: String) throws -> Data? { nil }
            func loadAll(prefix: String) throws -> [(key: String, data: Data)] { [] }
            func delete(key: String) throws {}
            func deleteAll(prefix: String) throws {}
        }
        let keychain = InMemoryKeychain()
        let svc = CheckoutService(clock: FakeClock(), keychain: keychain,
                                  persistence: FailingStore())
        let catalog = Catalog([SKU(id: "t1", kind: .ticket, title: "T1",
                                   priceCents: 100)])
        let cart = Cart(catalog: catalog)
        try cart.add(skuId: "t1", quantity: 1)
        let addr = USAddress(id: "a", recipient: "A", line1: "1",
                             city: "NYC", state: .NY, zip: "10001")
        let ship = ShippingTemplate(id: "std", name: "Std", feeCents: 500, etaDays: 3)

        XCTAssertThrowsError(try svc.submit(orderId: "O1",
                                             userId: customer.id,
                                             cart: cart, discounts: [],
                                             address: addr, shipping: ship,
                                             invoiceNotes: "",
                                             actingUser: customer)) { err in
            XCTAssertEqual(err as? CheckoutError, .persistenceFailed)
        }
        // No side effects: keychain has no order hash, orderStore has no entry.
        XCTAssertNil(svc.storedHash(for: "O1"),
                     "hash must NOT be sealed when persist failed")
        XCTAssertNil(svc.order("O1", ownedBy: customer.id),
                     "orderStore must NOT contain the order when persist failed")

        // The same orderId must be retryable after the store recovers.
        let svc2 = CheckoutService(clock: FakeClock(),
                                   keychain: keychain,
                                   persistence: InMemoryPersistenceStore())
        XCTAssertNoThrow(try svc2.submit(orderId: "O1",
                                         userId: customer.id,
                                         cart: cart, discounts: [],
                                         address: addr, shipping: ship,
                                         invoiceNotes: "",
                                         actingUser: customer))
    }

    // MARK: - Finding #6: Content editorId forgery rejected

    func testCreateDraftRejectsEditorIdThatIsNotTheCaller() {
        let svc = ContentPublishingService(clock: FakeClock(), battery: FakeBattery())
        XCTAssertThrowsError(try svc.createDraft(id: "c1", kind: .travelAdvisory,
                                                  title: "t", tag: TaxonomyTag(),
                                                  body: "b",
                                                  editorId: "someone-else",
                                                  actingUser: editor)) { err in
            XCTAssertEqual(err as? ContentError, .editorIdSpoof)
        }
    }

    func testEditRejectsEditorIdThatIsNotTheCaller() throws {
        let svc = ContentPublishingService(clock: FakeClock(), battery: FakeBattery())
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "t",
                                tag: TaxonomyTag(), body: "v1",
                                editorId: editor.id, actingUser: editor)
        XCTAssertThrowsError(try svc.edit(id: "c1", body: "v2",
                                          editorId: "someone-else",
                                          actingUser: editor)) { err in
            XCTAssertEqual(err as? ContentError, .editorIdSpoof)
        }
    }

    func testCreateDraftRecordsActingUserAsEditor() throws {
        let svc = ContentPublishingService(clock: FakeClock(), battery: FakeBattery())
        let item = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "t",
                                       tag: TaxonomyTag(), body: "v1",
                                       editorId: editor.id, actingUser: editor)
        XCTAssertEqual(item.versions.first?.editedBy, editor.id,
                       "editedBy audit field must match the authenticated actingUser")
    }

    // MARK: - Finding #1 (pass-#2): Seat reserve/confirm holder identity binding

    private func seatServiceWithOneSeat() -> (SeatInventoryService, SeatKey) {
        let svc = SeatInventoryService(clock: FakeClock())
        let seat = SeatKey(trainId: "T1", date: "2024-01-01", segmentId: "A-B",
                           seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(seat)
        return (svc, seat)
    }

    /// A customer-role caller with id "c1" must NOT be able to reserve a seat
    /// under any other holderId — otherwise they could mint reservations in
    /// someone else's name, bypassing object-level authorization.
    func testCustomerCannotReserveUnderDifferentHolderId() {
        let (svc, seat) = seatServiceWithOneSeat()
        XCTAssertThrowsError(try svc.reserve(seat, holderId: "someone-else",
                                              actingUser: customer)) { err in
            XCTAssertEqual(err as? SeatError, .wrongHolder,
                           "non-agent caller must not reserve with a holderId that isn't their own")
        }
    }

    /// A customer-role caller MUST be able to reserve a seat under their own
    /// `holderId` (the normal self-purchase path).
    func testCustomerCanReserveUnderOwnHolderId() throws {
        let (svc, seat) = seatServiceWithOneSeat()
        XCTAssertNoThrow(try svc.reserve(seat, holderId: customer.id,
                                         actingUser: customer))
    }

    /// A sales agent (`.processTransaction`) MUST be able to reserve on behalf
    /// of an arbitrary customer holderId — that's the point of the on-behalf
    /// carve-out. The guard must only kick in for non-agent roles.
    func testSalesAgentCanReserveOnBehalfOfAnyHolderId() throws {
        let (svc, seat) = seatServiceWithOneSeat()
        XCTAssertNoThrow(try svc.reserve(seat, holderId: "someone-else",
                                         actingUser: agent))
    }

    /// Same identity-binding guard applies to `confirm`. A customer cannot
    /// confirm a reservation they do not hold, even if the seat is reserved.
    func testCustomerCannotConfirmUnderDifferentHolderId() throws {
        let (svc, seat) = seatServiceWithOneSeat()
        // Set up a reservation held by someone else via the agent on-behalf path.
        _ = try svc.reserve(seat, holderId: "someone-else", actingUser: agent)
        XCTAssertThrowsError(try svc.confirm(seat, holderId: "someone-else",
                                              actingUser: customer)) { err in
            XCTAssertEqual(err as? SeatError, .wrongHolder,
                           "non-agent caller must not confirm a reservation under a holderId that isn't their own")
        }
    }

    /// Customer confirming their own reservation must succeed.
    func testCustomerCanConfirmOwnReservation() throws {
        let (svc, seat) = seatServiceWithOneSeat()
        _ = try svc.reserve(seat, holderId: customer.id, actingUser: customer)
        XCTAssertNoThrow(try svc.confirm(seat, holderId: customer.id,
                                         actingUser: customer))
    }

    /// Sales agent confirming on-behalf of any customer must succeed (the
    /// seat-inventory counterpart of `CheckoutService`'s on-behalf flow).
    func testSalesAgentCanConfirmOnBehalfOfAnyHolderId() throws {
        let (svc, seat) = seatServiceWithOneSeat()
        _ = try svc.reserve(seat, holderId: "someone-else", actingUser: agent)
        XCTAssertNoThrow(try svc.confirm(seat, holderId: "someone-else",
                                         actingUser: agent))
    }
}
