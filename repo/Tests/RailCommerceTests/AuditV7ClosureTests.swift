import XCTest
@testable import RailCommerce

/// Closure tests for the second-cycle architecture/security audit.
///
/// Covers:
/// - Release login bootstrap (`CredentialStore.hasAnyCredentials()`).
/// - User-scoped address isolation (`AddressBook.addresses(for:)`).
/// - User-scoped cart persistence (`Cart(ownerUserId:)` / `RailCommerce.cart(forUser:)`).
/// - Talent-search auth: no public unguarded entry point remains.
/// - Content rollback preserves customer-visible publication.
/// - Membership points: non-positive accrual/redeem rejected.
/// - Persistence failures on critical mutators propagate and roll back state.
final class AuditV7ClosureTests: XCTestCase {

    // MARK: - Release login bootstrap

    func testKeychainCredentialStoreIsEmptyOnFirstInstall() {
        let keychain = InMemoryKeychain()
        let store = KeychainCredentialStore(keychain: keychain)
        XCTAssertFalse(store.hasAnyCredentials(),
                       "fresh install must report no credentials so the UI can offer enrollment")
    }

    func testKeychainCredentialStoreReportsCredentialsAfterEnrollment() throws {
        let keychain = InMemoryKeychain()
        let store = KeychainCredentialStore(keychain: keychain)
        try store.enroll(username: "admin", password: "AdminPass!2024",
                         user: User(id: "a1", displayName: "Admin", role: .administrator))
        XCTAssertTrue(store.hasAnyCredentials(),
                      "after enrollment the bootstrap hint must be hidden")
    }

    // MARK: - Address user-isolation

    private func validAddress(id: String = "a1", owner: String? = nil,
                              isDefault: Bool = false) -> USAddress {
        USAddress(id: id, recipient: "R", line1: "1 Main", city: "NYC",
                  state: .NY, zip: "10001", isDefault: isDefault, ownerUserId: owner)
    }

    func testAddressBookAddressesForUserFiltersByOwner() throws {
        let book = AddressBook()
        _ = try book.save(validAddress(id: "a-alice", owner: "alice"))
        _ = try book.save(validAddress(id: "a-bob", owner: "bob"))
        XCTAssertEqual(book.addresses(for: "alice").map { $0.id }, ["a-alice"])
        XCTAssertEqual(book.addresses(for: "bob").map { $0.id }, ["a-bob"])
    }

    func testAddressBookDefaultScopedPerUser() throws {
        let book = AddressBook()
        // Alice's first (and only) address becomes her default.
        _ = try book.save(validAddress(id: "a-alice", owner: "alice"))
        // Bob's save must NOT demote Alice's default.
        _ = try book.save(validAddress(id: "a-bob", owner: "bob", isDefault: true))
        XCTAssertEqual(book.defaultAddress(for: "alice")?.id, "a-alice")
        XCTAssertEqual(book.defaultAddress(for: "bob")?.id, "a-bob")
        XCTAssertTrue(book.defaultAddress(for: "alice")?.isDefault ?? false,
                      "Alice's address must stay default despite Bob's save")
    }

    func testAddressBookRemoveOwnedByRejectsCrossUserDeletion() throws {
        let book = AddressBook()
        _ = try book.save(validAddress(id: "a-alice", owner: "alice"))
        // Bob attempts to delete Alice's record — must be a no-op.
        book.remove(id: "a-alice", ownedBy: "bob")
        XCTAssertEqual(book.addresses(for: "alice").map { $0.id }, ["a-alice"])
        // Alice's own remove succeeds.
        book.remove(id: "a-alice", ownedBy: "alice")
        XCTAssertTrue(book.addresses(for: "alice").isEmpty)
    }

    func testAddressBookSaveOwnedByStampsOwner() throws {
        let book = AddressBook()
        let unowned = USAddress(id: "a1", recipient: "R", line1: "1 Main",
                                city: "NYC", state: .NY, zip: "10001")
        let saved = try book.save(unowned, ownedBy: "alice")
        XCTAssertEqual(saved.ownerUserId, "alice")
    }

    // MARK: - Cart user-isolation

    private func makeCatalog() -> Catalog {
        Catalog([SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 1_000)])
    }

    func testCartUserScopedPersistenceKey() {
        let cart = Cart(catalog: makeCatalog(),
                        persistence: InMemoryPersistenceStore(),
                        ownerUserId: "alice")
        XCTAssertEqual(cart.persistenceKey, "cart.lines.alice")
    }

    func testCartLinesDoNotLeakAcrossUsers() throws {
        let store = InMemoryPersistenceStore()
        let catalog = makeCatalog()
        let aliceCart = Cart(catalog: catalog, persistence: store, ownerUserId: "alice")
        try aliceCart.add(skuId: "t1", quantity: 2)
        XCTAssertEqual(aliceCart.lines.count, 1)

        // A different user's cart hydrates from the user-scoped key and must
        // see nothing from Alice's session.
        let bobCart = Cart(catalog: catalog, persistence: store, ownerUserId: "bob")
        XCTAssertTrue(bobCart.lines.isEmpty)

        // A fresh Alice cart (simulated re-login on same device) rehydrates her lines.
        let aliceRehydrated = Cart(catalog: catalog, persistence: store, ownerUserId: "alice")
        XCTAssertEqual(aliceRehydrated.lines.first?.quantity, 2)
    }

    func testRailCommerceCartForUserReturnsSameInstancePerUser() {
        let app = RailCommerce()
        let c1 = app.cart(forUser: "alice")
        let c2 = app.cart(forUser: "alice")
        XCTAssertTrue(c1 === c2, "same user must get the same in-memory cart")
        let cBob = app.cart(forUser: "bob")
        XCTAssertFalse(c1 === cBob, "different users must get different carts")
    }

    func testRailCommerceClearCartForUserEvictsInMemoryCart() throws {
        let app = RailCommerce()
        app.catalog.upsert(SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 1_000))
        let aliceCart = app.cart(forUser: "alice")
        try aliceCart.add(skuId: "t1", quantity: 1)
        app.clearCart(forUser: "alice")
        let next = app.cart(forUser: "alice")
        XCTAssertFalse(next === aliceCart, "clearCart must evict the cached cart")
    }

    // MARK: - Talent search auth bypass closed

    func testTalentSearchOnlyPublicEntryPointRequiresUser() {
        // A compile-time contract: there is no public `search(_:)` overload, only
        // `search(_:, by:)`. This test pins the behavioral contract — an
        // unauthenticated role must fail.
        let svc = TalentMatchingService()
        svc.importResume(Resume(id: "r1", name: "A", skills: ["swift"],
                                yearsExperience: 3, certifications: []))
        let customer = User(id: "c", displayName: "C", role: .customer)
        XCTAssertThrowsError(try svc.search(TalentSearchCriteria(wantedSkills: ["swift"]),
                                            by: customer)) { err in
            if case .forbidden(required: let perm) = err as? AuthorizationError {
                XCTAssertEqual(perm, .matchTalent)
            } else {
                XCTFail("Expected AuthorizationError.forbidden(.matchTalent)")
            }
        }
    }

    func testTalentSearchAllowedForEveryRoleThatHoldsMatchTalent() throws {
        let svc = TalentMatchingService()
        svc.importResume(Resume(id: "r1", name: "A", skills: ["swift"],
                                yearsExperience: 3, certifications: []))
        for role in Role.allCases where RolePolicy.can(role, .matchTalent) {
            let u = User(id: "u_\(role.rawValue)", displayName: "U", role: role)
            XCTAssertNoThrow(try svc.search(TalentSearchCriteria(wantedSkills: ["swift"]),
                                            by: u))
        }
    }

    // MARK: - Content rollback semantics

    private func makeContentService() -> (ContentPublishingService, FakeClock,
                                          User, User) {
        let clock = FakeClock()
        let svc = ContentPublishingService(clock: clock, battery: FakeBattery())
        let editor = User(id: "e1", displayName: "Ed", role: .contentEditor)
        let reviewer = User(id: "r1", displayName: "Ri", role: .contentReviewer)
        return (svc, clock, editor, reviewer)
    }

    func testRollbackOfPublishedItemKeepsItPublished() throws {
        let (svc, _, editor, reviewer) = makeContentService()
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "T",
                                tag: TaxonomyTag(), body: "v1",
                                editorId: editor.id, actingUser: editor)
        _ = try svc.edit(id: "c1", body: "v2", editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        try svc.approve(id: "c1", reviewer: reviewer)
        XCTAssertEqual(svc.get("c1")?.status, .published)

        try svc.rollback(id: "c1", actingUser: reviewer)
        let item = svc.get("c1")!
        XCTAssertEqual(item.currentVersion, 1,
                       "rollback must revert the content version")
        XCTAssertEqual(item.status, .published,
                       "rollback of a published item must preserve customer visibility")

        // Customer-visible listing (publishedOnly) must still include the item.
        let listed = svc.items(publishedOnly: true)
        XCTAssertTrue(listed.contains { $0.id == "c1" },
                      "rolled-back published item must remain browseable")
    }

    // MARK: - Membership points validation

    func testAccruePointsRejectsNegative() throws {
        let svc = MembershipService()
        let admin = User(id: "admin", displayName: "A", role: .administrator)
        _ = try svc.enroll(userId: "u1", actingUser: admin)
        XCTAssertThrowsError(try svc.accruePoints(userId: "u1", points: -50, actingUser: admin)) { err in
            XCTAssertEqual(err as? MembershipError, .invalidPoints)
        }
        XCTAssertEqual(svc.member("u1")?.pointsBalance, 0,
                       "balance must not change on invalid accrual")
    }

    func testAccruePointsRejectsZero() throws {
        let svc = MembershipService()
        let admin = User(id: "admin", displayName: "A", role: .administrator)
        _ = try svc.enroll(userId: "u1", actingUser: admin)
        XCTAssertThrowsError(try svc.accruePoints(userId: "u1", points: 0, actingUser: admin)) { err in
            XCTAssertEqual(err as? MembershipError, .invalidPoints)
        }
    }

    func testRedeemPointsRejectsNegative() throws {
        let svc = MembershipService()
        let admin = User(id: "admin", displayName: "A", role: .administrator)
        let customer = User(id: "u1", displayName: "C", role: .customer)
        _ = try svc.enroll(userId: "u1", actingUser: customer)
        try svc.accruePoints(userId: "u1", points: 100, actingUser: admin)
        XCTAssertThrowsError(try svc.redeemPoints(userId: "u1", points: -10, actingUser: customer)) { err in
            XCTAssertEqual(err as? MembershipError, .invalidPoints)
        }
        XCTAssertEqual(svc.member("u1")?.pointsBalance, 100,
                       "balance must not increase on negative redeem")
    }

    // MARK: - Persistence failure handling

    /// Persistence store that fails on the first write of the first key
    /// matching `failingKeyPrefix`. Used to exercise rollback paths.
    private final class FailingPersistenceStore: PersistenceStore {
        let failingKeyPrefix: String
        var failOnSave = true
        var inner: [String: Data] = [:]

        init(failingKeyPrefix: String) { self.failingKeyPrefix = failingKeyPrefix }

        func save(key: String, data: Data) throws {
            if failOnSave && key.hasPrefix(failingKeyPrefix) {
                throw PersistenceError.encodingFailed
            }
            inner[key] = data
        }
        func load(key: String) throws -> Data? { inner[key] }
        func loadAll(prefix: String) throws -> [(key: String, data: Data)] {
            inner.filter { $0.key.hasPrefix(prefix) }
                 .map { (key: $0.key, data: $0.value) }
                 .sorted { $0.key < $1.key }
        }
        func delete(key: String) throws { inner.removeValue(forKey: key) }
        func deleteAll(prefix: String) throws {
            for k in inner.keys where k.hasPrefix(prefix) { inner.removeValue(forKey: k) }
        }
    }

    func testAddressBookSavePropagatesPersistenceFailure() {
        let failing = FailingPersistenceStore(failingKeyPrefix: AddressBook.persistencePrefix)
        let book = AddressBook(persistence: failing)
        let addr = validAddress(id: "a1", owner: "alice")
        XCTAssertThrowsError(try book.save(addr)) { err in
            XCTAssertEqual(err as? AddressBookError, .persistenceFailed,
                           "persistence failure must propagate")
        }
        XCTAssertTrue(book.addresses.isEmpty,
                      "in-memory state must roll back when durable write fails")
    }

    func testSeatReservePropagatesPersistenceFailure() throws {
        let failing = FailingPersistenceStore(failingKeyPrefix: SeatInventoryService.reservationsPrefix)
        let svc = SeatInventoryService(clock: FakeClock(), persistence: failing)
        let seat = SeatKey(trainId: "T1", date: "2024-01-01", segmentId: "A-B",
                           seatClass: .economy, seatNumber: "1A")
        // registerSeat writes states (allowed by prefix), so let states succeed.
        svc.registerSeat(seat)
        let customer = User(id: "c1", displayName: "C", role: .customer)
        XCTAssertThrowsError(try svc.reserve(seat, holderId: "c1", actingUser: customer))
        // State rolled back to .available and reservation not recorded.
        XCTAssertEqual(svc.state(seat), .available,
                       "state must revert to .available when reservation persistence fails")
        XCTAssertNil(svc.reservation(seat),
                     "failed reservation must not be observable after the error")
    }

    // MARK: - Cart durability

    func testCartAddPropagatesPersistenceFailure() throws {
        let failing = FailingPersistenceStore(failingKeyPrefix: Cart.persistenceKey)
        let cart = Cart(catalog: makeCatalog(), persistence: failing)
        XCTAssertThrowsError(try cart.add(skuId: "t1", quantity: 1)) { err in
            XCTAssertEqual(err as? CartError, .persistenceFailed,
                           "add must surface persistence failures instead of swallowing them")
        }
        XCTAssertTrue(cart.lines.isEmpty,
                      "line must roll back when durable write fails")
    }

    func testCartUpdatePropagatesPersistenceFailure() throws {
        let failing = FailingPersistenceStore(failingKeyPrefix: Cart.persistenceKey)
        // Let the initial add succeed by disabling failing writes, then re-enable
        // before the update we want to exercise.
        failing.failOnSave = false
        let cart = Cart(catalog: makeCatalog(), persistence: failing)
        try cart.add(skuId: "t1", quantity: 1)
        failing.failOnSave = true
        XCTAssertThrowsError(try cart.update(skuId: "t1", quantity: 5)) { err in
            XCTAssertEqual(err as? CartError, .persistenceFailed)
        }
        XCTAssertEqual(cart.lines.first?.quantity, 1,
                       "update must roll back quantity when durable write fails")
    }

    func testCartRemovePropagatesPersistenceFailure() throws {
        let failing = FailingPersistenceStore(failingKeyPrefix: Cart.persistenceKey)
        failing.failOnSave = false
        let cart = Cart(catalog: makeCatalog(), persistence: failing)
        try cart.add(skuId: "t1", quantity: 2)
        failing.failOnSave = true
        XCTAssertThrowsError(try cart.remove(skuId: "t1")) { err in
            XCTAssertEqual(err as? CartError, .persistenceFailed)
        }
        XCTAssertEqual(cart.lines.first?.quantity, 2,
                       "remove must roll back when durable write fails")
    }

    func testCartClearRollsBackOnPersistenceFailure() throws {
        let failing = FailingPersistenceStore(failingKeyPrefix: Cart.persistenceKey)
        failing.failOnSave = false
        let cart = Cart(catalog: makeCatalog(), persistence: failing)
        try cart.add(skuId: "t1", quantity: 3)
        failing.failOnSave = true
        XCTAssertThrowsError(try cart.clear()) { err in
            XCTAssertEqual(err as? CartError, .persistenceFailed,
                           "clear must surface persistence failures instead of swallowing them")
        }
        XCTAssertEqual(cart.lines.count, 1,
                       "clear must roll back the in-memory removal when durable write fails")
        XCTAssertEqual(cart.lines.first?.quantity, 3)
    }

    // MARK: - Seat sweep + audit rollback durability

    func testSeatSweepExpiredRollsBackOnPersistenceFailure() throws {
        // Allow initial reserve to succeed; fail the subsequent sweep write.
        final class ToggleableFailingStore: PersistenceStore {
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
            func delete(key: String) throws { inner.removeValue(forKey: key) }
            func deleteAll(prefix: String) throws {
                if failOnSave { throw PersistenceError.encodingFailed }
                for k in inner.keys where k.hasPrefix(prefix) { inner.removeValue(forKey: k) }
            }
        }
        let store = ToggleableFailingStore()
        let clock = FakeClock()
        let svc = SeatInventoryService(clock: clock, persistence: store)
        let seat = SeatKey(trainId: "T1", date: "2024-01-01", segmentId: "A-B",
                           seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(seat)
        let customer = User(id: "c1", displayName: "C", role: .customer)
        _ = try svc.reserve(seat, holderId: "c1", actingUser: customer)
        XCTAssertEqual(svc.state(seat), .reserved)

        // Advance past the 15-minute hold and make persistence fail during sweep.
        clock.advance(by: 16 * 60)
        store.failOnSave = true
        // Any state/reservation read triggers sweepExpired. It must roll back
        // rather than leave in-memory state diverged from disk.
        _ = svc.state(seat)
        XCTAssertEqual(svc.state(seat), .reserved,
                       "sweep must roll back when durable write fails; reservation stays reserved for retry")
        XCTAssertNotNil(svc.reservation(seat),
                        "reservation must still be observable after failed sweep")
    }

    func testSeatAuditRollbackPropagatesPersistenceFailure() throws {
        let store = InMemoryPersistenceStore()
        let clock = FakeClock()
        let svc = SeatInventoryService(clock: clock, persistence: store)
        let seat = SeatKey(trainId: "T1", date: "2024-01-01", segmentId: "A-B",
                           seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(seat)
        let customer = User(id: "c1", displayName: "C", role: .customer)
        // Snapshot BEFORE reservation so rollback targets "available".
        try svc.snapshot(date: "2024-01-01")
        _ = try svc.reserve(seat, holderId: "c1", actingUser: customer)

        // Swap in a store that fails writes, then rebuild svc on top of the
        // hydrated state from the previous store.
        let failing = FailingPersistenceStore(failingKeyPrefix: SeatInventoryService.statesPrefix)
        // Seed failing store with current state so hydration picks it up.
        failing.failOnSave = false
        for (k, v) in (try store.loadAll(prefix: "")) {
            try failing.save(key: k, data: v)
        }
        failing.failOnSave = true
        let svc2 = SeatInventoryService(clock: clock, persistence: failing)
        XCTAssertThrowsError(try svc2.rollback(to: "2024-01-01"),
                             "rollback must throw when durable write fails")
        XCTAssertEqual(svc2.state(seat), .reserved,
                       "state must revert to pre-rollback values when persistence fails")
    }

    // MARK: - Content scheduled-publish durability

    func testProcessScheduledRedefersOnPersistenceFailure() throws {
        final class ToggleableFailingStore: PersistenceStore {
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
            func delete(key: String) throws { inner.removeValue(forKey: key) }
            func deleteAll(prefix: String) throws {
                for k in inner.keys where k.hasPrefix(prefix) { inner.removeValue(forKey: k) }
            }
        }
        let store = ToggleableFailingStore()
        let clock = FakeClock()
        let svc = ContentPublishingService(clock: clock, battery: FakeBattery(),
                                           persistence: store)
        let editor = User(id: "e1", displayName: "Ed", role: .contentEditor)
        let reviewer = User(id: "r1", displayName: "Ri", role: .contentReviewer)
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "T",
                                tag: TaxonomyTag(), body: "v1",
                                editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        try svc.schedule(id: "c1", at: clock.now().addingTimeInterval(60), reviewer: reviewer)
        clock.advance(by: 120)

        // Make the publish-time persist fail.
        store.failOnSave = true
        let published = svc.processScheduled()
        XCTAssertTrue(published.isEmpty,
                      "persistence failure must prevent the item from being reported as published")
        XCTAssertEqual(svc.get("c1")?.status, .scheduled,
                       "item must roll back to .scheduled when durable write fails")
        XCTAssertEqual(svc.deferredProcessing, ["c1"],
                       "failed items must be re-deferred so the next tick retries")

        // When the store recovers, the next tick must publish successfully.
        store.failOnSave = false
        let publishedRetry = svc.processScheduled()
        XCTAssertEqual(publishedRetry, ["c1"],
                       "retry after recovery must publish the previously-failed item")
        XCTAssertEqual(svc.get("c1")?.status, .published)
        XCTAssertTrue(svc.deferredProcessing.isEmpty)
    }
}
