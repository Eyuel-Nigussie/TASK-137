import XCTest
@testable import RailCommerce

/// Tests for object-level data isolation in AfterSalesService.requestsVisible.
final class AfterSalesIsolationTests: XCTestCase {

    private let alice = User(id: "alice", displayName: "Alice", role: .customer)
    private let bob = User(id: "bob", displayName: "Bob", role: .customer)
    private let csr = User(id: "csr", displayName: "CSR", role: .customerService)
    private let admin = User(id: "admin", displayName: "Admin", role: .administrator)

    private func setup() -> AfterSalesService {
        AfterSalesService(clock: FakeClock(),
                          camera: FakeCamera(granted: true),
                          notifier: LocalNotificationBus())
    }

    func testCustomerSeesOnlyOwnRequests() throws {
        let svc = setup()
        let reqA = AfterSalesRequest(id: "RA", orderId: "OA", kind: .refundOnly,
                                     reason: .changedMind, createdAt: Date(),
                                     serviceDate: Date(), amountCents: 500)
        let reqB = AfterSalesRequest(id: "RB", orderId: "OB", kind: .refundOnly,
                                     reason: .changedMind, createdAt: Date(),
                                     serviceDate: Date(), amountCents: 500)
        try svc.open(reqA, actingUser: alice)
        try svc.open(reqB, actingUser: bob)
        let aliceVisible = try svc.requestsVisible(to: "alice", actingUser: alice)
        XCTAssertEqual(aliceVisible.map { $0.id }, ["RA"])
        let bobVisible = try svc.requestsVisible(to: "bob", actingUser: bob)
        XCTAssertEqual(bobVisible.map { $0.id }, ["RB"])
    }

    func testCSRSeesAll() throws {
        let svc = setup()
        let reqA = AfterSalesRequest(id: "RA", orderId: "OA", kind: .refundOnly,
                                     reason: .changedMind, createdAt: Date(),
                                     serviceDate: Date(), amountCents: 500)
        let reqB = AfterSalesRequest(id: "RB", orderId: "OB", kind: .refundOnly,
                                     reason: .changedMind, createdAt: Date(),
                                     serviceDate: Date(), amountCents: 500)
        try svc.open(reqA, actingUser: alice)
        try svc.open(reqB, actingUser: bob)
        let csrVisible = try svc.requestsVisible(to: "csr", actingUser: csr)
        XCTAssertEqual(csrVisible.count, 2)
    }

    func testAdminSeesAll() throws {
        let svc = setup()
        try svc.open(AfterSalesRequest(id: "RA", orderId: "OA", kind: .refundOnly,
                                       reason: .changedMind, createdAt: Date(),
                                       serviceDate: Date(), amountCents: 500),
                     actingUser: alice)
        let adminVisible = try svc.requestsVisible(to: "admin", actingUser: admin)
        XCTAssertEqual(adminVisible.count, 1)
    }

    /// Regression: a non-privileged caller must NOT be able to read another user's
    /// requests by passing a spoofed target userId. The API must throw rather than
    /// silently return the other user's data.
    func testCustomerCannotSpoofTargetUserId() throws {
        let svc = setup()
        try svc.open(AfterSalesRequest(id: "RA", orderId: "OA", kind: .refundOnly,
                                       reason: .changedMind, createdAt: Date(),
                                       serviceDate: Date(), amountCents: 500),
                     actingUser: alice)
        // Bob (non-privileged) tries to read Alice's requests by spoofing userId.
        XCTAssertThrowsError(try svc.requestsVisible(to: "alice", actingUser: bob)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden for spoofed target") }
        }
    }

    func testCustomerQueryingOwnIdWhenEmptyReturnsEmpty() throws {
        let svc = setup()
        try svc.open(AfterSalesRequest(id: "RA", orderId: "OA", kind: .refundOnly,
                                       reason: .changedMind, createdAt: Date(),
                                       serviceDate: Date(), amountCents: 500),
                     actingUser: alice)
        // Bob has no requests but queries his OWN id — allowed, returns empty.
        let bobVisible = try svc.requestsVisible(to: "bob", actingUser: bob)
        XCTAssertTrue(bobVisible.isEmpty)
    }

    /// The fool-proof `requestsVisible(actingUser:)` overload cannot be misused
    /// with a spoofed target id — it only returns the caller's own data for
    /// non-privileged roles, and full audit data for CSR/admin.
    func testRequestsVisibleActingUserOverloadIsIsolatedByConstruction() throws {
        let svc = setup()
        try svc.open(AfterSalesRequest(id: "RA", orderId: "OA", kind: .refundOnly,
                                       reason: .changedMind, createdAt: Date(),
                                       serviceDate: Date(), amountCents: 500),
                     actingUser: alice)
        try svc.open(AfterSalesRequest(id: "RB", orderId: "OB", kind: .refundOnly,
                                       reason: .changedMind, createdAt: Date(),
                                       serviceDate: Date(), amountCents: 500),
                     actingUser: bob)
        XCTAssertEqual(svc.requestsVisible(actingUser: alice).map { $0.id }, ["RA"])
        XCTAssertEqual(svc.requestsVisible(actingUser: bob).map { $0.id }, ["RB"])
        XCTAssertEqual(svc.requestsVisible(actingUser: csr).count, 2)
        XCTAssertEqual(svc.requestsVisible(actingUser: admin).count, 2)
    }

    func testOpenStampsCreatedByUserId() throws {
        let svc = setup()
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind, createdAt: Date(),
                                    serviceDate: Date(), amountCents: 500)
        let opened = try svc.open(req, actingUser: alice)
        XCTAssertEqual(opened.createdByUserId, "alice")
        XCTAssertEqual(svc.get("R1")?.createdByUserId, "alice")
    }
}
