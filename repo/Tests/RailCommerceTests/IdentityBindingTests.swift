import XCTest
@testable import RailCommerce

/// Security tests for identity binding at service write paths. Prevents authenticated
/// users from forging `userId` / `from` identifiers.
final class IdentityBindingTests: XCTestCase {

    // MARK: - CheckoutService.submit

    private func checkoutSetup() -> (CheckoutService, Cart, USAddress, ShippingTemplate) {
        let service = CheckoutService(clock: FakeClock(), keychain: InMemoryKeychain())
        let catalog = Catalog([SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 1_000)])
        let cart = Cart(catalog: catalog)
        try! cart.add(skuId: "t1", quantity: 1)
        let address = USAddress(id: "a1", recipient: "A", line1: "1 Main",
                                city: "NYC", state: .NY, zip: "10001")
        let shipping = ShippingTemplate(id: "std", name: "Standard", feeCents: 500, etaDays: 3)
        return (service, cart, address, shipping)
    }

    func testCustomerCannotSubmitOrderAsDifferentUser() {
        let (svc, cart, addr, ship) = checkoutSetup()
        let alice = User(id: "alice", displayName: "Alice", role: .customer)
        XCTAssertThrowsError(try svc.submit(orderId: "O1", userId: "bob", cart: cart,
                                            discounts: [], address: addr, shipping: ship,
                                            invoiceNotes: "", actingUser: alice)) { err in
            XCTAssertEqual(err as? CheckoutError, .identityMismatch)
        }
    }

    func testCustomerCanSubmitOrderAsSelf() throws {
        let (svc, cart, addr, ship) = checkoutSetup()
        let alice = User(id: "alice", displayName: "Alice", role: .customer)
        XCTAssertNoThrow(try svc.submit(orderId: "O1", userId: "alice", cart: cart,
                                        discounts: [], address: addr, shipping: ship,
                                        invoiceNotes: "", actingUser: alice))
    }

    func testSalesAgentCanSubmitOrderOnBehalfOfAnyUser() throws {
        let (svc, cart, addr, ship) = checkoutSetup()
        let sam = User(id: "sam", displayName: "Sam", role: .salesAgent)
        // Sales agents have .processTransaction and may transact for any customer.
        XCTAssertNoThrow(try svc.submit(orderId: "O2", userId: "some-customer", cart: cart,
                                        discounts: [], address: addr, shipping: ship,
                                        invoiceNotes: "", actingUser: sam))
    }

    func testAdminCanSubmitOrderOnBehalfOfAnyUser() throws {
        let (svc, cart, addr, ship) = checkoutSetup()
        let dan = User(id: "dan", displayName: "Dan", role: .administrator)
        // Admin has all permissions including .processTransaction.
        XCTAssertNoThrow(try svc.submit(orderId: "O3", userId: "some-customer", cart: cart,
                                        discounts: [], address: addr, shipping: ship,
                                        invoiceNotes: "", actingUser: dan))
    }

    func testCheckoutDuplicateSubmissionRejectedByPermanentIdempotency() throws {
        let (svc, cart, addr, ship) = checkoutSetup()
        let alice = User(id: "alice", displayName: "Alice", role: .customer)
        let clock = FakeClock()
        // Use fresh service with advanceable clock for the long-window test.
        let fresh = CheckoutService(clock: clock, keychain: InMemoryKeychain())
        _ = try fresh.submit(orderId: "O9", userId: "alice", cart: cart, discounts: [],
                             address: addr, shipping: ship, invoiceNotes: "", actingUser: alice)
        clock.advance(by: 60 * 60 * 24) // a full day later
        let cart2 = Cart(catalog: Catalog([SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 1_000)]))
        try cart2.add(skuId: "t1", quantity: 1)
        XCTAssertThrowsError(try fresh.submit(orderId: "O9", userId: "alice", cart: cart2,
                                              discounts: [], address: addr, shipping: ship,
                                              invoiceNotes: "", actingUser: alice)) { err in
            XCTAssertEqual(err as? CheckoutError, .duplicateSubmission)
        }
    }

    // MARK: - MessagingService.enqueue

    func testCustomerCannotEnqueueWithSpoofedSender() {
        let svc = MessagingService(clock: FakeClock())
        let alice = User(id: "alice", displayName: "Alice", role: .customer)
        XCTAssertThrowsError(try svc.enqueue(id: "m1", from: "bob", to: "carol",
                                             body: "hi", actingUser: alice)) { err in
            XCTAssertEqual(err as? MessagingError, .senderIdentityMismatch)
        }
    }

    func testCustomerCanEnqueueAsSelf() throws {
        let svc = MessagingService(clock: FakeClock())
        let alice = User(id: "alice", displayName: "Alice", role: .customer)
        XCTAssertNoThrow(try svc.enqueue(id: "m1", from: "alice", to: "carol",
                                         body: "hi", actingUser: alice))
    }

    func testCSRCanEnqueueAsOtherStaff() throws {
        let svc = MessagingService(clock: FakeClock())
        let csr = User(id: "csr1", displayName: "CSR", role: .customerService)
        // CSR has .sendStaffMessage — may send on behalf of staff peers.
        XCTAssertNoThrow(try svc.enqueue(id: "m1", from: "agent1", to: "agent2",
                                         body: "hi", actingUser: csr))
    }

    func testAdminCanEnqueueAsAnyUser() throws {
        let svc = MessagingService(clock: FakeClock())
        let admin = User(id: "admin", displayName: "Admin", role: .administrator)
        XCTAssertNoThrow(try svc.enqueue(id: "m1", from: "anyone", to: "bob",
                                         body: "hi", actingUser: admin))
    }

    // MARK: - messagesVisibleTo object-level isolation

    func testMessagesVisibleToOwnerAllowed() throws {
        let svc = MessagingService(clock: FakeClock())
        let alice = User(id: "alice", displayName: "Alice", role: .customer)
        _ = try svc.enqueue(id: "m1", from: "alice", to: "bob", body: "hi", actingUser: alice)
        _ = svc.drainQueue()
        let msgs = try svc.messagesVisibleTo("alice", actingUser: alice)
        XCTAssertEqual(msgs.count, 1)
    }

    func testMessagesVisibleToForbiddenForRandomPeer() throws {
        let svc = MessagingService(clock: FakeClock())
        let alice = User(id: "alice", displayName: "Alice", role: .customer)
        let bob = User(id: "bob", displayName: "Bob", role: .customer)
        _ = try svc.enqueue(id: "m1", from: "alice", to: "carol", body: "hi", actingUser: alice)
        _ = svc.drainQueue()
        XCTAssertThrowsError(try svc.messagesVisibleTo("alice", actingUser: bob)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected forbidden") }
        }
    }

    func testMessagesVisibleToAllowedForCSR() throws {
        let svc = MessagingService(clock: FakeClock())
        let alice = User(id: "alice", displayName: "Alice", role: .customer)
        let csr = User(id: "csr", displayName: "CSR", role: .customerService)
        _ = try svc.enqueue(id: "m1", from: "alice", to: "bob", body: "hi", actingUser: alice)
        _ = svc.drainQueue()
        // CSR can audit any user's messages via .handleServiceTickets.
        let msgs = try svc.messagesVisibleTo("alice", actingUser: csr)
        XCTAssertEqual(msgs.count, 1)
    }

    func testMessagesVisibleToAllowedForAdmin() throws {
        let svc = MessagingService(clock: FakeClock())
        let alice = User(id: "alice", displayName: "Alice", role: .customer)
        let admin = User(id: "admin", displayName: "Admin", role: .administrator)
        _ = try svc.enqueue(id: "m1", from: "alice", to: "bob", body: "hi", actingUser: alice)
        _ = svc.drainQueue()
        XCTAssertNoThrow(try svc.messagesVisibleTo("alice", actingUser: admin))
    }
}
