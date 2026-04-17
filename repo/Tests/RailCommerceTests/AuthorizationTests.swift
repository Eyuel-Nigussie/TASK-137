import XCTest
@testable import RailCommerce

/// Tests for `AuthorizationError` and the role-enforcement guard added to each service.
final class AuthorizationTests: XCTestCase {

    // MARK: - AuthorizationError

    func testForbiddenErrorEquality() {
        XCTAssertEqual(AuthorizationError.forbidden(required: .purchase),
                       AuthorizationError.forbidden(required: .purchase))
        XCTAssertNotEqual(AuthorizationError.forbidden(required: .purchase),
                          AuthorizationError.forbidden(required: .manageUsers))
    }

    func testEnforcePassesWhenPermitted() throws {
        let admin = User(id: "a", displayName: "Admin", role: .administrator)
        XCTAssertNoThrow(try RolePolicy.enforce(user: admin, .manageUsers))
    }

    func testEnforceThrowsWhenForbidden() {
        let editor = User(id: "e", displayName: "Ed", role: .contentEditor)
        XCTAssertThrowsError(try RolePolicy.enforce(user: editor, .manageUsers)) { err in
            if case .forbidden(let p) = err as? AuthorizationError {
                XCTAssertEqual(p, .manageUsers)
            } else {
                XCTFail("Expected AuthorizationError.forbidden")
            }
        }
    }

    // MARK: - CheckoutService auth

    private func checkoutSetup() -> (CheckoutService, Cart, USAddress, ShippingTemplate) {
        let clock = FakeClock()
        let keychain = InMemoryKeychain()
        let service = CheckoutService(clock: clock, keychain: keychain)
        let catalog = Catalog([SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 1_000)])
        let cart = Cart(catalog: catalog)
        try! cart.add(skuId: "t1", quantity: 1)
        let address = USAddress(id: "a1", recipient: "A", line1: "1 Main",
                                city: "NYC", state: .NY, zip: "10001")
        let shipping = ShippingTemplate(id: "std", name: "Standard", feeCents: 500, etaDays: 3)
        return (service, cart, address, shipping)
    }

    func testCheckoutAllowedForCustomer() throws {
        let (svc, cart, addr, ship) = checkoutSetup()
        let customer = User(id: "c1", displayName: "Alice", role: .customer)
        XCTAssertNoThrow(try svc.submit(orderId: "O1", userId: "c1", cart: cart,
                                        discounts: [], address: addr,
                                        shipping: ship, invoiceNotes: "",
                                        actingUser: customer))
    }

    func testCheckoutAllowedForSalesAgent() throws {
        let (svc, cart, addr, ship) = checkoutSetup()
        let agent = User(id: "a1", displayName: "Sam", role: .salesAgent)
        XCTAssertNoThrow(try svc.submit(orderId: "O2", userId: "a1", cart: cart,
                                        discounts: [], address: addr,
                                        shipping: ship, invoiceNotes: "",
                                        actingUser: agent))
    }

    func testCheckoutForbiddenForContentEditor() {
        let (svc, cart, addr, ship) = checkoutSetup()
        let editor = User(id: "e1", displayName: "Eve", role: .contentEditor)
        XCTAssertThrowsError(try svc.submit(orderId: "O3", userId: "e1", cart: cart,
                                            discounts: [], address: addr,
                                            shipping: ship, invoiceNotes: "",
                                            actingUser: editor)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }

    // MARK: - AfterSalesService auth

    private func afterSalesSetup() -> (AfterSalesService, AfterSalesRequest) {
        let clock = FakeClock()
        let svc = AfterSalesService(clock: clock,
                                    camera: FakeCamera(granted: true),
                                    notifier: LocalNotificationBus())
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind,
                                    createdAt: clock.now(), serviceDate: clock.now(),
                                    amountCents: 500)
        return (svc, req)
    }

    func testAfterSalesOpenAllowedForCustomer() throws {
        let (svc, req) = afterSalesSetup()
        let customer = User(id: "c1", displayName: "Alice", role: .customer)
        XCTAssertNoThrow(try svc.open(req, actingUser: customer))
    }

    func testAfterSalesOpenForbiddenForContentEditor() {
        let (svc, req) = afterSalesSetup()
        let editor = User(id: "e1", displayName: "Eve", role: .contentEditor)
        XCTAssertThrowsError(try svc.open(req, actingUser: editor)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }

    func testAfterSalesApproveAllowedForCSR() throws {
        let (svc, req) = afterSalesSetup()
        let customer = User(id: "c1", displayName: "Alice", role: .customer)
        let csr = User(id: "s1", displayName: "Chris", role: .customerService)
        try svc.open(req, actingUser: customer)
        XCTAssertNoThrow(try svc.approve(id: req.id, actingUser: csr))
    }

    func testAfterSalesApproveForbiddenForCustomer() throws {
        let (svc, req) = afterSalesSetup()
        let customer = User(id: "c1", displayName: "Alice", role: .customer)
        try svc.open(req, actingUser: customer)
        XCTAssertThrowsError(try svc.approve(id: req.id, actingUser: customer)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }

    func testAfterSalesRejectAllowedForCSR() throws {
        let (svc, req) = afterSalesSetup()
        let customer = User(id: "c1", displayName: "Alice", role: .customer)
        let csr = User(id: "s1", displayName: "Chris", role: .customerService)
        try svc.open(req, actingUser: customer)
        XCTAssertNoThrow(try svc.reject(id: req.id, actingUser: csr))
    }

    func testAfterSalesRejectForbiddenForCustomer() throws {
        let (svc, req) = afterSalesSetup()
        let customer = User(id: "c1", displayName: "Alice", role: .customer)
        try svc.open(req, actingUser: customer)
        XCTAssertThrowsError(try svc.reject(id: req.id, actingUser: customer)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }

    // MARK: - SeatInventoryService auth

    private func seatSetup() -> (SeatInventoryService, SeatKey) {
        let svc = SeatInventoryService(clock: FakeClock())
        let key = SeatKey(trainId: "T1", date: "2024-01-02", segmentId: "S1",
                          seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(key)
        return (svc, key)
    }

    func testSeatReserveAllowedForCustomer() throws {
        let (svc, key) = seatSetup()
        let customer = User(id: "c1", displayName: "Alice", role: .customer)
        XCTAssertNoThrow(try svc.reserve(key, holderId: "c1", actingUser: customer))
    }

    func testSeatReserveAllowedForSalesAgent() throws {
        let (svc, key) = seatSetup()
        let agent = User(id: "a1", displayName: "Sam", role: .salesAgent)
        XCTAssertNoThrow(try svc.reserve(key, holderId: "a1", actingUser: agent))
    }

    func testSeatReserveForbiddenForContentEditor() {
        let (svc, key) = seatSetup()
        let editor = User(id: "e1", displayName: "Eve", role: .contentEditor)
        XCTAssertThrowsError(try svc.reserve(key, holderId: "e1", actingUser: editor)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }

    func testSeatConfirmAllowedForCustomer() throws {
        let (svc, key) = seatSetup()
        let customer = User(id: "c1", displayName: "Alice", role: .customer)
        try svc.reserve(key, holderId: "c1", actingUser: customer)
        XCTAssertNoThrow(try svc.confirm(key, holderId: "c1", actingUser: customer))
    }

    func testSeatConfirmAllowedForSalesAgent() throws {
        let (svc, key) = seatSetup()
        let agent = User(id: "a1", displayName: "Sam", role: .salesAgent)
        try svc.reserve(key, holderId: "a1", actingUser: agent)
        // Sales agent has .processTransaction (not .purchase) — should still be permitted.
        XCTAssertNoThrow(try svc.confirm(key, holderId: "a1", actingUser: agent))
    }

    func testSeatConfirmForbiddenForReviewer() throws {
        let (svc, key) = seatSetup()
        let customer = User(id: "c1", displayName: "Alice", role: .customer)
        let reviewer = User(id: "r1", displayName: "Rita", role: .contentReviewer)
        try svc.reserve(key, holderId: "c1", actingUser: customer)
        XCTAssertThrowsError(try svc.confirm(key, holderId: "c1", actingUser: reviewer)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }

    // MARK: - ContentPublishingService auth (createDraft overload)

    func testCreateDraftAllowedForEditor() throws {
        let svc = ContentPublishingService(clock: FakeClock(), battery: FakeBattery())
        let editor = User(id: "e1", displayName: "Eve", role: .contentEditor)
        XCTAssertNoThrow(try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "T",
                                             tag: TaxonomyTag(), body: "v1",
                                             editorId: editor.id, actingUser: editor))
    }

    func testCreateDraftForbiddenForCustomer() {
        let svc = ContentPublishingService(clock: FakeClock(), battery: FakeBattery())
        let customer = User(id: "c1", displayName: "Alice", role: .customer)
        XCTAssertThrowsError(try svc.createDraft(id: "c2", kind: .travelAdvisory, title: "T",
                                                 tag: TaxonomyTag(), body: "v1",
                                                 editorId: customer.id, actingUser: customer)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }

    func testEditAllowedForEditorWithActingUser() throws {
        let svc = ContentPublishingService(clock: FakeClock(), battery: FakeBattery())
        let editor = User(id: "e1", displayName: "Eve", role: .contentEditor)
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "T",
                                tag: TaxonomyTag(), body: "v1", editorId: editor.id, actingUser: editor)
        XCTAssertNoThrow(try svc.edit(id: "c1", body: "v2",
                                      editorId: editor.id, actingUser: editor))
    }

    func testEditForbiddenForReviewer() throws {
        let svc = ContentPublishingService(clock: FakeClock(), battery: FakeBattery())
        let editor = User(id: "e1", displayName: "Eve", role: .contentEditor)
        let reviewer = User(id: "r1", displayName: "Rita", role: .contentReviewer)
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "T",
                                tag: TaxonomyTag(), body: "v1", editorId: editor.id, actingUser: editor)
        XCTAssertThrowsError(try svc.edit(id: "c1", body: "v2",
                                          editorId: reviewer.id, actingUser: reviewer)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }

    // MARK: - TalentMatchingService auth

    func testTalentSearchAllowedForAdmin() throws {
        let svc = TalentMatchingService()
        svc.importResume(Resume(id: "r1", name: "Alice", skills: ["swift"],
                                yearsExperience: 5, certifications: []))
        let admin = User(id: "a1", displayName: "Dan", role: .administrator)
        XCTAssertNoThrow(try svc.search(TalentSearchCriteria(wantedSkills: ["swift"]),
                                        by: admin))
    }

    func testTalentSearchForbiddenForCustomer() {
        let svc = TalentMatchingService()
        let customer = User(id: "c1", displayName: "Alice", role: .customer)
        XCTAssertThrowsError(try svc.search(TalentSearchCriteria(), by: customer)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }

    // MARK: - MessagingService auth

    func testMessagingAllowedForAllRoles() throws {
        let svc = MessagingService(clock: FakeClock())
        for role in Role.allCases {
            let user = User(id: "u_\(role.rawValue)", displayName: "U", role: role)
            XCTAssertNoThrow(
                try svc.enqueue(id: UUID().uuidString, from: user.id, to: "target",
                                body: "hello", actingUser: user),
                "Role \(role) should be able to message"
            )
        }
    }
}
