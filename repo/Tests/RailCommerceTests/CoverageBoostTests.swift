import XCTest
@testable import RailCommerce

/// Targeted coverage tests for the handful of low-coverage paths that remained
/// after the audit-closure work. Each test here is pinned to a specific source
/// region (noted in the // `Covers:` comment) that was previously unreached by
/// the main suites. These are intentionally small and focused — there's one
/// scenario per uncovered region so regressions are pinpointable.
final class CoverageBoostTests: XCTestCase {

    // MARK: - Shared toggleable failing store

    /// Persistence store that fails every save/delete when `failOnSave` is true.
    /// File-scoped here so every test in this class can lean on the same fixture.
    final class ToggleStore: PersistenceStore {
        var failOnSave = false
        var inner: [String: Data] = [:]
        func save(key: String, data: Data) throws {
            if failOnSave { throw PersistenceError.encodingFailed }
            inner[key] = data
        }
        func load(key: String) throws -> Data? { inner[key] }
        func loadAll(prefix: String) throws -> [(key: String, data: Data)] {
            inner.filter { $0.key.hasPrefix(prefix) }
                 .map { (key: $0.key, data: $0.value) }
                 .sorted { $0.key < $1.key }
        }
        func delete(key: String) throws {
            if failOnSave { throw PersistenceError.encodingFailed }
            inner.removeValue(forKey: key)
        }
        func deleteAll(prefix: String) throws {
            if failOnSave { throw PersistenceError.encodingFailed }
            for k in inner.keys where k.hasPrefix(prefix) {
                inner.removeValue(forKey: k)
            }
        }
    }

    /// Store whose `loadAll` always throws, so hydrate paths exercise their
    /// catch branches.
    final class HydrateFailingStore: PersistenceStore {
        func save(key: String, data: Data) throws {}
        func load(key: String) throws -> Data? { nil }
        func loadAll(prefix: String) throws -> [(key: String, data: Data)] {
            throw PersistenceError.decodingFailed
        }
        func delete(key: String) throws {}
        func deleteAll(prefix: String) throws {}
    }

    private let admin = User(id: "admin", displayName: "Admin", role: .administrator)
    private let customer = User(id: "u1", displayName: "U", role: .customer)
    private let csr = User(id: "csr", displayName: "CSR", role: .customerService)
    private let editor = User(id: "e1", displayName: "Ed", role: .contentEditor)
    private let reviewer = User(id: "r1", displayName: "Ri", role: .contentReviewer)

    // MARK: - CredentialStore protocol default

    /// Covers: `CredentialStore.hasAnyCredentials()` default-implementation
    /// branch in `Core/CredentialStore.swift:44` — callers that don't override
    /// the method get `true` so they never accidentally open the bootstrap path.
    func testCredentialStoreProtocolDefaultHasAnyCredentials() {
        final class Stub: CredentialStore {
            func enroll(username: String, password: String, user: User) throws {}
            func verify(username: String, password: String) -> User? { nil }
            func user(forUsername username: String) -> User? { nil }
            func remove(username: String) throws {}
            // hasAnyCredentials intentionally not overridden.
        }
        XCTAssertTrue(Stub().hasAnyCredentials(),
                      "protocol default must report credentials exist so unaware impls don't open bootstrap UI")
    }

    // MARK: - Catalog rollback

    /// Covers: `Catalog.upsert` rollback (Models/Catalog.swift:46-47).
    func testCatalogUpsertRollsBackOnPersistenceFailure() {
        let failing = ToggleStore()
        let catalog = Catalog(persistence: failing)
        failing.failOnSave = true
        let sku = SKU(id: "s1", kind: .ticket, title: "T", priceCents: 100)
        catalog.upsert(sku)
        XCTAssertNil(catalog.get("s1"),
                     "upsert must roll back when durable write fails")
    }

    /// Covers: `Catalog.remove` rollback (Models/Catalog.swift:57).
    func testCatalogRemoveRollsBackOnPersistenceFailure() {
        let failing = ToggleStore()
        let catalog = Catalog(persistence: failing)
        let sku = SKU(id: "s1", kind: .ticket, title: "T", priceCents: 100)
        catalog.upsert(sku)
        failing.failOnSave = true
        catalog.remove(id: "s1")
        XCTAssertNotNil(catalog.get("s1"),
                        "remove must roll back when durable delete fails")
    }

    // MARK: - AddressBook hydrate

    /// Covers: `AddressBook.hydrate` decode-loop (Models/Address.swift:178-180)
    /// — a fresh book instance must load previously-persisted records so
    /// address history survives restart.
    func testAddressBookHydratesFromPersistence() throws {
        let store = InMemoryPersistenceStore()
        let book1 = AddressBook(persistence: store)
        _ = try book1.save(USAddress(id: "a1", recipient: "R", line1: "1 Main",
                                     city: "NYC", state: .NY, zip: "10001"),
                           ownedBy: "alice")

        let book2 = AddressBook(persistence: store)
        XCTAssertEqual(book2.addresses(for: "alice").map { $0.id }, ["a1"],
                       "rehydrated book must see alice's saved address")
    }

    // MARK: - Cart hydrate early-return

    /// Covers: `Cart.hydrate` `catch { return }` path (Services/Cart.swift:142)
    /// — when the persistence store itself fails on `load`, hydration must
    /// bail cleanly instead of propagating.
    func testCartHydrateSurvivesLoadFailure() {
        final class FailingLoadStore: PersistenceStore {
            func save(key: String, data: Data) throws {}
            func load(key: String) throws -> Data? { throw PersistenceError.decodingFailed }
            func loadAll(prefix: String) throws -> [(key: String, data: Data)] { [] }
            func delete(key: String) throws {}
            func deleteAll(prefix: String) throws {}
        }
        let cart = Cart(catalog: Catalog(), persistence: FailingLoadStore())
        XCTAssertTrue(cart.lines.isEmpty,
                      "cart must initialize empty when hydrate can't read the store")
    }

    // MARK: - CheckoutService: seats paths

    private func checkoutCatalog() -> Catalog {
        Catalog([SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 1_000)])
    }

    /// Covers: `CheckoutService.submit` seats-without-inventory guard
    /// (Services/CheckoutService.swift:174-175).
    func testCheckoutWithSeatsButNoInventoryThrows() throws {
        let clock = FakeClock()
        let svc = CheckoutService(clock: clock, keychain: InMemoryKeychain())
        let cart = Cart(catalog: checkoutCatalog())
        try cart.add(skuId: "t1", quantity: 1)
        let addr = USAddress(id: "a", recipient: "A", line1: "1",
                             city: "NYC", state: .NY, zip: "10001")
        let ship = ShippingTemplate(id: "std", name: "Std", feeCents: 500, etaDays: 3)
        let seat = SeatKey(trainId: "T1", date: "2024-01-01", segmentId: "A-B",
                           seatClass: .economy, seatNumber: "1A")
        XCTAssertThrowsError(try svc.submit(orderId: "O1", userId: customer.id,
                                            cart: cart, discounts: [],
                                            address: addr, shipping: ship,
                                            invoiceNotes: "", actingUser: customer,
                                            seats: [seat],
                                            seatInventory: nil))
    }

    /// Covers: `CheckoutService.submit` seats-already-held-by-someone-else
    /// branch (Services/CheckoutService.swift:187).
    func testCheckoutSeatHeldByAnotherUserRejected() throws {
        let clock = FakeClock()
        let inv = SeatInventoryService(clock: clock)
        let svc = CheckoutService(clock: clock, keychain: InMemoryKeychain())
        let cart = Cart(catalog: checkoutCatalog())
        try cart.add(skuId: "t1", quantity: 1)

        let seat = SeatKey(trainId: "T1", date: "2024-01-01", segmentId: "A-B",
                           seatClass: .economy, seatNumber: "1A")
        inv.registerSeat(seat)
        let holder = User(id: "other", displayName: "Other", role: .customer)
        _ = try inv.reserve(seat, holderId: holder.id, actingUser: holder)

        let addr = USAddress(id: "a", recipient: "A", line1: "1",
                             city: "NYC", state: .NY, zip: "10001")
        let ship = ShippingTemplate(id: "std", name: "Std", feeCents: 500, etaDays: 3)
        XCTAssertThrowsError(try svc.submit(orderId: "O1", userId: customer.id,
                                            cart: cart, discounts: [],
                                            address: addr, shipping: ship,
                                            invoiceNotes: "", actingUser: customer,
                                            seats: [seat], seatInventory: inv))
    }

    /// Covers: `CheckoutService.submit` persistence-failure path
    /// (Services/CheckoutService.swift:219-220) and hydrate error path (:235).
    func testCheckoutPersistFailurePropagates() throws {
        let clock = FakeClock()
        let failing = ToggleStore()
        let svc = CheckoutService(clock: clock, keychain: InMemoryKeychain(),
                                  persistence: failing)
        let cart = Cart(catalog: checkoutCatalog())
        try cart.add(skuId: "t1", quantity: 1)
        let addr = USAddress(id: "a", recipient: "A", line1: "1",
                             city: "NYC", state: .NY, zip: "10001")
        let ship = ShippingTemplate(id: "std", name: "Std", feeCents: 500, etaDays: 3)
        failing.failOnSave = true
        XCTAssertThrowsError(try svc.submit(orderId: "O1", userId: customer.id,
                                            cart: cart, discounts: [],
                                            address: addr, shipping: ship,
                                            invoiceNotes: "", actingUser: customer))
    }

    func testCheckoutHydrateTolerantOfStoreFailure() {
        _ = CheckoutService(clock: FakeClock(), keychain: InMemoryKeychain(),
                            persistence: HydrateFailingStore())
    }

    // MARK: - MembershipService rollback & hydrate

    /// Covers: `MembershipService.tagMember` rollback + hydrate failure
    /// branches (Services/MembershipService.swift:159-161, :246).
    func testMembershipTagRollbackPropagates() throws {
        let failing = ToggleStore()
        let svc = MembershipService(persistence: failing)
        _ = try svc.enroll(userId: "u1", actingUser: admin)
        failing.failOnSave = true
        XCTAssertThrowsError(try svc.tagMember(userId: "u1", tag: "vip", actingUser: admin))
        XCTAssertFalse(svc.member("u1")?.tags.contains("vip") ?? true,
                       "tag must roll back when persistence fails")
    }

    func testMembershipDeactivateCampaignRollbackPropagates() throws {
        let failing = ToggleStore()
        let svc = MembershipService(persistence: failing)
        _ = try svc.createCampaign(
            MarketingCampaign(id: "c1", name: "N", offerDescription: "O"),
            actingUser: admin)
        failing.failOnSave = true
        XCTAssertThrowsError(try svc.deactivateCampaign("c1", actingUser: admin))
        XCTAssertEqual(svc.campaign("c1")?.active, true,
                       "deactivate must roll back on persistence failure")
    }

    func testMembershipHydrateSurvivesStoreFailure() {
        _ = MembershipService(persistence: HydrateFailingStore())
    }

    // MARK: - TalentMatchingService rollback + persistence + hydrate

    func testTalentBulkTagRollbackOnPersistFailure() {
        let failing = ToggleStore()
        let svc = TalentMatchingService(persistence: failing)
        svc.importResume(Resume(id: "r1", name: "A", skills: ["swift"],
                                yearsExperience: 1, certifications: []))
        failing.failOnSave = true
        svc.bulkTag(ids: ["r1"], add: "vip")
        // Prior record must be restored and the tag stripped from the index.
        XCTAssertFalse(svc.allResumes().first?.tags.contains("vip") ?? true,
                       "bulkTag must roll back when persist fails")
    }

    func testTalentSaveSearchRollbackOnPersistFailure() {
        let failing = ToggleStore()
        let svc = TalentMatchingService(persistence: failing)
        failing.failOnSave = true
        svc.saveSearch(SavedSearch(id: "s1", name: "X",
                                   wantedSkills: ["swift"],
                                   wantedCertifications: [], desiredYears: 1))
        XCTAssertNil(svc.savedSearch("s1"),
                     "saveSearch must roll back when persistence fails")
    }

    func testTalentPersistSavedSearchErrorPath() {
        // Exercise the throwing persistSavedSearch branch by replacing a known
        // record — first save succeeds (so the prior exists), second save fails.
        let failing = ToggleStore()
        let svc = TalentMatchingService(persistence: failing)
        svc.saveSearch(SavedSearch(id: "s1", name: "N1",
                                   wantedSkills: [], wantedCertifications: [],
                                   desiredYears: 1))
        failing.failOnSave = true
        svc.saveSearch(SavedSearch(id: "s1", name: "N2",
                                   wantedSkills: [], wantedCertifications: [],
                                   desiredYears: 2))
        XCTAssertEqual(svc.savedSearch("s1")?.name, "N1",
                       "rollback must restore prior saved search")
    }

    func testTalentHydrateSurvivesStoreFailure() {
        _ = TalentMatchingService(persistence: HydrateFailingStore())
    }

    // MARK: - AttachmentService: persistence failure + hydrate + helpers

    func testAttachmentSavePropagatesPersistenceFailure() {
        let failing = ToggleStore()
        let svc = AttachmentService(clock: FakeClock(),
                                    persistence: failing,
                                    fileStore: InMemoryFileStore(),
                                    basePath: "/tmp/t")
        failing.failOnSave = true
        XCTAssertThrowsError(try svc.save(id: "a1", data: Data([1, 2, 3]),
                                          kind: .jpeg))
    }

    func testAttachmentHydrateSurvivesStoreFailure() {
        _ = AttachmentService(clock: FakeClock(),
                              persistence: HydrateFailingStore(),
                              fileStore: InMemoryFileStore(),
                              basePath: "/tmp/t")
    }

    func testInMemoryFileStoreCountMatchesWrites() throws {
        let store = InMemoryFileStore()
        try store.write(data: Data([1]), to: "/x/a")
        try store.write(data: Data([2]), to: "/x/b")
        XCTAssertEqual(store.count, 2)
        try store.delete(at: "/x/a")
        XCTAssertEqual(store.count, 1)
    }

    // MARK: - MessagingService: error paths + queued hydrate + attachment switch

    /// Covers: `MessagingService` persistence error branch
    /// (Services/MessagingService.swift:448-449).
    func testMessagingEnqueuePropagatesPersistenceFailure() throws {
        let failing = ToggleStore()
        let svc = MessagingService(clock: FakeClock(), persistence: failing)
        failing.failOnSave = true
        XCTAssertThrowsError(try svc.enqueue(id: "m1", from: customer.id,
                                             to: "agent", body: "hi",
                                             actingUser: customer)) { err in
            XCTAssertEqual(err as? MessagingError, .persistenceFailed)
        }
    }

    /// Covers: `MessagingService.drainQueue` persist-failure log branch
    /// (Services/MessagingService.swift:309-310).
    func testDrainQueueLogsPersistFailureWithoutUndeliveringMessage() throws {
        let failing = ToggleStore()
        let svc = MessagingService(clock: FakeClock(), persistence: failing)
        _ = try svc.enqueue(id: "m1", from: customer.id, to: "agent", body: "hi",
                            actingUser: customer)
        failing.failOnSave = true
        let delivered = svc.drainQueue()
        XCTAssertEqual(delivered.count, 1,
                       "message must still report delivered even when audit persist fails")
    }

    /// Covers: `MessagingService` inbound attachment `switch` (:413-415).
    func testInboundMessageWithAttachmentAccepted() {
        final class Xport: MessageTransport {
            var handlers: [(Message) -> Void] = []
            func send(_ message: Message) throws -> [String] { [] }
            func onReceive(_ h: @escaping (Message) -> Void) { handlers.append(h) }
            func start(asPeer peerId: String) throws {}
            func stop() {}
            var connectedPeers: [String] { [] }
            func deliver(_ msg: Message) { handlers.forEach { $0(msg) } }
        }
        let transport = Xport()
        let svc = MessagingService(clock: FakeClock(), transport: transport)
        let att = MessageAttachment(id: "a1", kind: .jpeg, sizeBytes: 1024)
        transport.deliver(Message(id: "m1", fromUserId: "peer",
                                  toUserId: customer.id, body: "hi",
                                  attachments: [att], createdAt: Date()))
        XCTAssertEqual(svc.deliveredMessages.count, 1,
                       "inbound message with valid attachment must pass the safety pipeline")
    }

    /// Covers: `MessagingService.hydrate` queued-append branch (:463-464).
    func testMessagingHydrateRestoresQueuedMessages() throws {
        let store = InMemoryPersistenceStore()
        let clock = FakeClock()
        // Manually persist a message with deliveredAt=nil so it hydrates as queued.
        let msg = Message(id: "m1", fromUserId: customer.id, toUserId: "agent",
                          body: "hi", createdAt: clock.now())
        let data = try JSONEncoder().encode(msg)
        try store.save(key: MessagingService.persistencePrefix + msg.id, data: data)
        let svc = MessagingService(clock: clock, persistence: store)
        XCTAssertEqual(svc.queue.count, 1,
                       "queued messages must be restored from persistence on hydrate")
    }

    func testMessagingHydrateSurvivesStoreFailure() {
        _ = MessagingService(clock: FakeClock(), persistence: HydrateFailingStore())
    }

    // MARK: - AfterSalesService: owner check + case-message wiring + runAutomation rollback

    /// Covers: `AfterSalesService.open` orderNotOwned branch
    /// (Services/AfterSalesService.swift:205-206).
    func testAfterSalesOpenRejectsRequestForOrderOwnedByAnotherUser() {
        let svc = AfterSalesService(clock: FakeClock(),
                                    camera: FakeCamera(granted: true),
                                    notifier: LocalNotificationBus(),
                                    orderOwnershipValidator: { _, _ in false })
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind,
                                    createdAt: Date(), serviceDate: Date(),
                                    amountCents: 500)
        XCTAssertThrowsError(try svc.open(req, actingUser: customer)) { err in
            XCTAssertEqual(err as? AfterSalesError, .orderNotOwned)
        }
    }

    /// Covers: `AfterSalesService.postCaseMessage` no-messenger path
    /// (Services/AfterSalesService.swift:166-167).
    func testPostCaseMessageWithoutMessengerThrows() throws {
        let svc = AfterSalesService(clock: FakeClock(),
                                    camera: FakeCamera(granted: true),
                                    notifier: LocalNotificationBus())
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind,
                                    createdAt: Date(), serviceDate: Date(),
                                    amountCents: 500)
        try svc.open(req, actingUser: customer)
        // messenger is never wired on this svc, so postCaseMessage must fail.
        XCTAssertThrowsError(try svc.postCaseMessage(requestId: "R1", to: csr.id,
                                                      body: "hi",
                                                      actingUser: csr))
    }

    /// Covers: `AfterSalesService.open` persistence-failure branch (:311-312).
    func testAfterSalesOpenPropagatesPersistenceFailure() {
        let failing = ToggleStore()
        let svc = AfterSalesService(clock: FakeClock(),
                                    camera: FakeCamera(granted: true),
                                    notifier: LocalNotificationBus(),
                                    persistence: failing)
        failing.failOnSave = true
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind,
                                    createdAt: Date(), serviceDate: Date(),
                                    amountCents: 500)
        XCTAssertThrowsError(try svc.open(req, actingUser: customer))
    }

    func testAfterSalesHydrateSurvivesStoreFailure() {
        _ = AfterSalesService(clock: FakeClock(),
                              camera: FakeCamera(granted: true),
                              notifier: LocalNotificationBus(),
                              persistence: HydrateFailingStore())
    }

    /// Covers: `runAutomation` autoReject + autoApprove rollback branches
    /// (Services/AfterSalesService.swift:413-418, :438-439).
    func testRunAutomationAutoRejectRollbackOnPersistFailure() throws {
        let failing = ToggleStore()
        let clock = FakeClock()
        let svc = AfterSalesService(clock: clock,
                                    camera: FakeCamera(granted: true),
                                    notifier: LocalNotificationBus(),
                                    persistence: failing)
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind,
                                    createdAt: clock.now(),
                                    serviceDate: clock.now(),
                                    amountCents: 500)
        try svc.open(req, actingUser: customer)
        clock.advance(by: 14 * 86_400 + 10)  // past auto-reject threshold
        failing.failOnSave = true
        let changed = svc.runAutomation()
        XCTAssertTrue(changed.isEmpty,
                      "auto-reject must not report changes when persistence fails")
        XCTAssertEqual(svc.get("R1")?.status, .pending,
                       "request must roll back to .open when persistence fails")
    }

    func testRunAutomationAutoApproveRollbackOnPersistFailure() throws {
        let failing = ToggleStore()
        let clock = FakeClock()
        let svc = AfterSalesService(clock: clock,
                                    camera: FakeCamera(granted: true),
                                    notifier: LocalNotificationBus(),
                                    persistence: failing)
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind,
                                    createdAt: clock.now(),
                                    serviceDate: clock.now().addingTimeInterval(86_400),
                                    amountCents: 100)  // < $25
        try svc.open(req, actingUser: customer)
        clock.advance(by: 49 * 3600)  // past 48h auto-approve threshold
        failing.failOnSave = true
        let changed = svc.runAutomation()
        XCTAssertTrue(changed.isEmpty)
        XCTAssertEqual(svc.get("R1")?.status, .pending)
    }

    // MARK: - SeatInventoryService: release/confirm rollback + registeredKeys sort + hydrate

    func testSeatReleaseRollbackPropagates() throws {
        let failing = ToggleStore()
        let clock = FakeClock()
        let svc = SeatInventoryService(clock: clock, persistence: failing)
        let seat = SeatKey(trainId: "T1", date: "2024-01-01", segmentId: "A-B",
                           seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(seat)
        _ = try svc.reserve(seat, holderId: customer.id, actingUser: customer)
        failing.failOnSave = true
        XCTAssertThrowsError(try svc.release(seat, holderId: customer.id,
                                             actingUser: customer))
        XCTAssertEqual(svc.state(seat), .reserved,
                       "release must roll back when persistence fails")
    }

    func testSeatConfirmRollbackPropagates() throws {
        let failing = ToggleStore()
        let clock = FakeClock()
        let svc = SeatInventoryService(clock: clock, persistence: failing)
        let seat = SeatKey(trainId: "T1", date: "2024-01-01", segmentId: "A-B",
                           seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(seat)
        _ = try svc.reserve(seat, holderId: customer.id, actingUser: customer)
        failing.failOnSave = true
        XCTAssertThrowsError(try svc.confirm(seat, holderId: customer.id,
                                             actingUser: customer))
        XCTAssertEqual(svc.state(seat), .reserved,
                       "confirm must roll back when persistence fails")
    }

    /// Covers: `registeredKeys` sort branch (Services/SeatInventoryService.swift:114-116).
    func testRegisteredKeysSortStable() {
        let svc = SeatInventoryService(clock: FakeClock())
        let a = SeatKey(trainId: "T1", date: "2024-01-01", segmentId: "A-B",
                        seatClass: .economy, seatNumber: "2A")
        let b = SeatKey(trainId: "T1", date: "2024-01-01", segmentId: "A-B",
                        seatClass: .economy, seatNumber: "1A")
        let c = SeatKey(trainId: "T1", date: "2024-01-01", segmentId: "A-B",
                        seatClass: .first, seatNumber: "1A")
        svc.registerSeat(a)
        svc.registerSeat(b)
        svc.registerSeat(c)
        let seatNumbers = svc.registeredKeys().map { "\($0.seatClass.rawValue)/\($0.seatNumber)" }
        XCTAssertEqual(seatNumbers.first, "economy/1A")
    }

    func testSeatHydrateSurvivesStoreFailure() {
        _ = SeatInventoryService(clock: FakeClock(), persistence: HydrateFailingStore())
    }

    // MARK: - ContentPublishingService hydrate error

    func testContentPublishingHydrateSurvivesStoreFailure() {
        _ = ContentPublishingService(clock: FakeClock(),
                                     battery: FakeBattery(),
                                     persistence: HydrateFailingStore())
    }

    // MARK: - FakeBiometricAuth paths

    func testFakeBiometricAuthAuthenticateFailurePath() {
        let fake = FakeBiometricAuth(available: true, succeeds: false)
        var result: Bool?
        fake.authenticate(reason: "r") { result = $0 }
        XCTAssertEqual(result, false)
    }

    func testFakeBiometricAuthUnavailable() {
        let fake = FakeBiometricAuth(available: false, succeeds: false)
        XCTAssertFalse(fake.isAvailable)
    }

    // MARK: - LocalBiometricAuth (LAContext-backed)

    /// Covers: `LocalBiometricAuth.init` and `isAvailable` path
    /// (Core/BiometricAuth.swift:31-35). We can't reliably assert a value for
    /// `isAvailable` because it depends on host device capability, but we can
    /// exercise the code path so it is no longer 0-coverage. Test runners on
    /// macOS typically return `false` (no enrolled biometrics), which is fine.
    #if canImport(LocalAuthentication)
    func testLocalBiometricAuthAvailabilityQueryDoesNotCrash() {
        let auth = LocalBiometricAuth()
        // Just exercise the getter — the returned value varies per host.
        _ = auth.isAvailable
    }
    #endif

    // MARK: - DiskFileStore (real filesystem path)

    /// Covers: `DiskFileStore` write/read/delete/exists
    /// (Services/AttachmentService.swift:33-48).
    func testDiskFileStoreRoundTrip() throws {
        let tmpRoot = NSTemporaryDirectory() + "coverage-disk-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmpRoot) }

        let path = tmpRoot + "/nested/attachment.bin"
        let store = DiskFileStore()

        XCTAssertFalse(store.exists(at: path))

        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try store.write(data: payload, to: path)
        XCTAssertTrue(store.exists(at: path),
                      "exists() must return true after write()")

        let read = try store.read(from: path)
        XCTAssertEqual(read, payload,
                       "read() must round-trip the bytes written by write()")

        try store.delete(at: path)
        XCTAssertFalse(store.exists(at: path),
                       "exists() must return false after delete()")
    }

    func testDiskFileStoreReadMissingThrows() {
        let store = DiskFileStore()
        let bogusPath = NSTemporaryDirectory() + "coverage-missing-\(UUID().uuidString).bin"
        XCTAssertThrowsError(try store.read(from: bogusPath))
    }

    func testDiskFileStoreDeleteMissingThrows() {
        let store = DiskFileStore()
        let bogusPath = NSTemporaryDirectory() + "coverage-missing-\(UUID().uuidString).bin"
        XCTAssertThrowsError(try store.delete(at: bogusPath))
    }
}
