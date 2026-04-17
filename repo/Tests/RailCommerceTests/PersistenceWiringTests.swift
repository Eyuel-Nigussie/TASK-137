import XCTest
@testable import RailCommerce

/// Tests verify that every service that accepts a `PersistenceStore` actually uses it:
/// mutations are persisted on write, and a second service constructed over the same
/// store hydrates the prior state.
final class PersistenceWiringTests: XCTestCase {

    // MARK: - CheckoutService

    func testCheckoutHydratesOrdersFromStore() throws {
        let store = InMemoryPersistenceStore()
        let clock = FakeClock()
        let keychain = InMemoryKeychain()
        let customer = User(id: "c1", displayName: "Alice", role: .customer)
        let svc = CheckoutService(clock: clock, keychain: keychain, persistence: store)
        let catalog = Catalog([SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 1_000)])
        let cart = Cart(catalog: catalog)
        try cart.add(skuId: "t1", quantity: 1)
        let address = USAddress(id: "a1", recipient: "A", line1: "1 Main",
                                city: "NYC", state: .NY, zip: "10001")
        let shipping = ShippingTemplate(id: "std", name: "Standard", feeCents: 500, etaDays: 3)
        _ = try svc.submit(orderId: "O-H1", userId: "c1", cart: cart, discounts: [],
                           address: address, shipping: shipping,
                           invoiceNotes: "", actingUser: customer)

        // Construct a fresh service over the same store — it must hydrate the order.
        let rebuilt = CheckoutService(clock: clock, keychain: keychain, persistence: store)
        XCTAssertNotNil(rebuilt.order("O-H1", ownedBy: "c1"))
    }

    // MARK: - AfterSalesService

    func testAfterSalesHydratesRequestsFromStore() throws {
        let store = InMemoryPersistenceStore()
        let clock = FakeClock()
        let customer = User(id: "c1", displayName: "Alice", role: .customer)
        let svc = AfterSalesService(clock: clock, camera: FakeCamera(granted: true),
                                    notifier: LocalNotificationBus(), persistence: store)
        let req = AfterSalesRequest(id: "R-H1", orderId: "O-H1", kind: .refundOnly,
                                    reason: .defective, createdAt: clock.now(),
                                    serviceDate: clock.now(), amountCents: 500)
        try svc.open(req, actingUser: customer)

        let rebuilt = AfterSalesService(clock: clock, camera: FakeCamera(granted: true),
                                        notifier: LocalNotificationBus(), persistence: store)
        XCTAssertNotNil(rebuilt.get("R-H1"))
    }

    func testAfterSalesTransitionsPersisted() throws {
        let store = InMemoryPersistenceStore()
        let clock = FakeClock()
        let customer = User(id: "c1", displayName: "Alice", role: .customer)
        let csr = User(id: "csr", displayName: "CSR", role: .customerService)
        let svc = AfterSalesService(clock: clock, camera: FakeCamera(granted: true),
                                    notifier: LocalNotificationBus(), persistence: store)
        let req = AfterSalesRequest(id: "R-T1", orderId: "O-T1", kind: .refundOnly,
                                    reason: .defective, createdAt: clock.now(),
                                    serviceDate: clock.now(), amountCents: 500)
        try svc.open(req, actingUser: customer)
        try svc.approve(id: "R-T1", actingUser: csr)

        let rebuilt = AfterSalesService(clock: clock, camera: FakeCamera(granted: true),
                                        notifier: LocalNotificationBus(), persistence: store)
        XCTAssertEqual(rebuilt.get("R-T1")?.status, .approved)
    }

    // MARK: - MessagingService

    func testMessagingHydratesMessagesFromStore() throws {
        let store = InMemoryPersistenceStore()
        let alice = User(id: "alice", displayName: "Alice", role: .customer)
        let svc = MessagingService(clock: FakeClock(), persistence: store)
        _ = try svc.enqueue(id: "m-H1", from: "alice", to: "bob", body: "hi", actingUser: alice)
        _ = svc.drainQueue()

        let rebuilt = MessagingService(clock: FakeClock(), persistence: store)
        XCTAssertEqual(rebuilt.messages(to: "bob").map { $0.id }, ["m-H1"])
    }

    // MARK: - SeatInventoryService

    func testSeatInventoryHydratesStateFromStore() throws {
        let store = InMemoryPersistenceStore()
        let clock = FakeClock()
        let customer = User(id: "c1", displayName: "Alice", role: .customer)
        let key = SeatKey(trainId: "T1", date: "2024-01-02", segmentId: "S1",
                          seatClass: .economy, seatNumber: "1A")
        let svc = SeatInventoryService(clock: clock, persistence: store)
        svc.registerSeat(key)
        _ = try svc.reserve(key, holderId: "c1", actingUser: customer)

        let rebuilt = SeatInventoryService(clock: clock, persistence: store)
        XCTAssertEqual(rebuilt.state(key), .reserved)
        XCTAssertNotNil(rebuilt.reservation(key))
    }

    // MARK: - ContentPublishingService

    func testContentHydratesDraftsFromStore() throws {
        let store = InMemoryPersistenceStore()
        let clock = FakeClock()
        let editor = User(id: "ed", displayName: "Ed", role: .contentEditor)
        let svc = ContentPublishingService(clock: clock, battery: FakeBattery(),
                                           persistence: store)
        _ = try svc.createDraft(id: "c-H1", kind: .travelAdvisory, title: "T",
                                tag: TaxonomyTag(), body: "v1",
                                editorId: editor.id, actingUser: editor)

        let rebuilt = ContentPublishingService(clock: clock, battery: FakeBattery(),
                                               persistence: store)
        XCTAssertEqual(rebuilt.get("c-H1")?.versions.first?.body, "v1")
    }

    // MARK: - TalentMatchingService

    func testTalentHydratesResumesFromStore() throws {
        let store = InMemoryPersistenceStore()
        let svc = TalentMatchingService(persistence: store)
        let r = Resume(id: "r-H1", name: "Alice", skills: ["swift"],
                       yearsExperience: 5, certifications: [])
        svc.importResume(r)
        svc.saveSearch(SavedSearch(id: "s-H1", name: "swift devs",
                                   wantedSkills: ["swift"], wantedCertifications: [], desiredYears: 3))

        let rebuilt = TalentMatchingService(persistence: store)
        XCTAssertEqual(rebuilt.allResumes().map { $0.id }, ["r-H1"])
        XCTAssertEqual(rebuilt.savedSearch("s-H1")?.name, "swift devs")
    }

    // MARK: - AttachmentService

    func testAttachmentHydratesFromStore() throws {
        let store = InMemoryPersistenceStore()
        let clock = FakeClock()
        let svc = AttachmentService(clock: clock, persistence: store)
        _ = try svc.save(id: "a-H1", data: Data([1, 2, 3]), kind: .jpeg)

        let rebuilt = AttachmentService(clock: clock, persistence: store)
        XCTAssertEqual(rebuilt.all().map { $0.id }, ["a-H1"])
    }

    func testAttachmentSweepRemovesFromStore() throws {
        let store = InMemoryPersistenceStore()
        let clock = FakeClock()
        let svc = AttachmentService(clock: clock, persistence: store)
        _ = try svc.save(id: "a-T1", data: Data([1]), kind: .jpeg)
        clock.advance(by: 31 * 86_400)
        _ = svc.runRetentionSweep()

        let rebuilt = AttachmentService(clock: clock, persistence: store)
        XCTAssertTrue(rebuilt.all().isEmpty)
    }

    // MARK: - InMemoryPersistenceStore basics

    func testInMemoryPersistenceStoreSaveAndLoad() throws {
        let store = InMemoryPersistenceStore()
        try store.save(key: "k1", data: Data([1, 2]))
        XCTAssertEqual(try store.load(key: "k1"), Data([1, 2]))
    }

    func testInMemoryPersistenceStoreLoadMissingReturnsNil() throws {
        let store = InMemoryPersistenceStore()
        XCTAssertNil(try store.load(key: "ghost"))
    }

    func testInMemoryPersistenceStoreLoadAllFiltersPrefix() throws {
        let store = InMemoryPersistenceStore()
        try store.save(key: "p.a", data: Data([1]))
        try store.save(key: "p.b", data: Data([2]))
        try store.save(key: "q.a", data: Data([3]))
        let entries = try store.loadAll(prefix: "p.")
        XCTAssertEqual(entries.map { $0.key }, ["p.a", "p.b"])
    }

    func testInMemoryPersistenceStoreDelete() throws {
        let store = InMemoryPersistenceStore()
        try store.save(key: "k", data: Data([1]))
        try store.delete(key: "k")
        XCTAssertNil(try store.load(key: "k"))
    }

    func testInMemoryPersistenceStoreDeleteAllPrefix() throws {
        let store = InMemoryPersistenceStore()
        try store.save(key: "p.a", data: Data([1]))
        try store.save(key: "p.b", data: Data([2]))
        try store.save(key: "q.a", data: Data([3]))
        try store.deleteAll(prefix: "p.")
        XCTAssertEqual(try store.loadAll(prefix: "").count, 1)
    }
}
