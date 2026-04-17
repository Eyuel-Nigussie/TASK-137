import XCTest
@testable import RailCommerce

/// Deeper coverage for the second-cycle audit fixes — focuses on edge cases,
/// legacy compatibility, boundary values, and cross-service integration
/// scenarios that complement `AuditV7ClosureTests`.
final class AuditV7ExtendedCoverageTests: XCTestCase {

    private let admin = User(id: "admin", displayName: "Admin", role: .administrator)
    private let alice = User(id: "alice", displayName: "Alice", role: .customer)

    // MARK: - Toggleable failing persistence store

    /// Persistence store whose write and delete paths can be selectively failed
    /// via `failOnSave`. Exposed at file scope so multiple tests share the same
    /// fixture surface (avoids re-defining per-test).
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
        func delete(key: String) throws {
            if failOnSave { throw PersistenceError.encodingFailed }
            inner.removeValue(forKey: key)
        }
        func deleteAll(prefix: String) throws {
            if failOnSave { throw PersistenceError.encodingFailed }
            for k in inner.keys where k.hasPrefix(prefix) { inner.removeValue(forKey: k) }
        }
    }

    // MARK: - Address: legacy unowned records remain invisible to user-scoped reads

    func testLegacyUnownedAddressesInvisibleInUserScopedReads() throws {
        // Simulate a pre-isolation install where addresses were stored without
        // an owner. New user-scoped reads must not leak those records.
        let book = AddressBook()
        let legacy = USAddress(id: "legacy", recipient: "L", line1: "1 Old St",
                               city: "NYC", state: .NY, zip: "10001")  // no ownerUserId
        _ = try book.save(legacy)
        XCTAssertTrue(book.addresses(for: "alice").isEmpty,
                      "legacy unowned records must not appear in any user's scoped view")
        XCTAssertNil(book.defaultAddress(for: "alice"))
    }

    func testUserScopedDefaultPromotionDoesNotDemoteAnotherUsersDefault() throws {
        let book = AddressBook()
        // Alice's first address becomes her default automatically.
        _ = try book.save(USAddress(id: "a-alice", recipient: "A", line1: "1",
                                    city: "NYC", state: .NY, zip: "10001"),
                          ownedBy: "alice")
        // Bob explicitly marks his address default — this must NOT demote Alice.
        _ = try book.save(USAddress(id: "a-bob", recipient: "B", line1: "2",
                                    city: "NYC", state: .NY, zip: "10001",
                                    isDefault: true),
                          ownedBy: "bob")
        XCTAssertTrue(book.defaultAddress(for: "alice")?.isDefault ?? false,
                      "Alice's default must remain after Bob's default save")
        XCTAssertTrue(book.defaultAddress(for: "bob")?.isDefault ?? false,
                      "Bob's new default must be set")
    }

    func testUserScopedDefaultPromotionDemotesOnlyOwnUserPriorDefaults() throws {
        let book = AddressBook()
        _ = try book.save(USAddress(id: "a-alice-1", recipient: "A1", line1: "1",
                                    city: "NYC", state: .NY, zip: "10001"),
                          ownedBy: "alice")
        _ = try book.save(USAddress(id: "a-alice-2", recipient: "A2", line1: "2",
                                    city: "NYC", state: .NY, zip: "10001",
                                    isDefault: true),
                          ownedBy: "alice")
        // Exactly one Alice default.
        let aliceDefaults = book.addresses(for: "alice").filter { $0.isDefault }
        XCTAssertEqual(aliceDefaults.count, 1)
        XCTAssertEqual(aliceDefaults.first?.id, "a-alice-2")
    }

    func testRemoveOwnedByOnlyTouchesRequestingUser() throws {
        let book = AddressBook()
        _ = try book.save(USAddress(id: "a-alice", recipient: "A", line1: "1",
                                    city: "NYC", state: .NY, zip: "10001"),
                          ownedBy: "alice")
        _ = try book.save(USAddress(id: "a-bob", recipient: "B", line1: "2",
                                    city: "NYC", state: .NY, zip: "10001"),
                          ownedBy: "bob")
        // Alice tries to delete Bob's record under her own userId scope — no-op.
        book.remove(id: "a-bob", ownedBy: "alice")
        XCTAssertEqual(book.addresses(for: "bob").map { $0.id }, ["a-bob"])
        XCTAssertEqual(book.addresses(for: "alice").map { $0.id }, ["a-alice"])
    }

    func testAddressBookSaveRollbackPreservesPriorList() throws {
        let failing = ToggleableFailingStore()
        failing.failOnSave = false
        let book = AddressBook(persistence: failing)
        _ = try book.save(USAddress(id: "a1", recipient: "A", line1: "1 Main",
                                    city: "NYC", state: .NY, zip: "10001"),
                          ownedBy: "alice")

        failing.failOnSave = true
        XCTAssertThrowsError(try book.save(USAddress(id: "a2", recipient: "B", line1: "2 Main",
                                                     city: "NYC", state: .NY, zip: "10001"),
                                           ownedBy: "alice"))
        // The failed save must not affect the previously-persisted record.
        XCTAssertEqual(book.addresses(for: "alice").map { $0.id }, ["a1"],
                       "rollback must preserve exactly the prior state")
    }

    // MARK: - Cart: durability + legacy behavior + hydration across sessions

    private func makeCatalog() -> Catalog {
        Catalog([
            SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 1_000),
            SKU(id: "t2", kind: .ticket, title: "T2", priceCents: 2_000)
        ])
    }

    func testCartLegacyUnscopedPersistenceKeyUnchanged() {
        // Back-compat: carts without ownerUserId still use "cart.lines" key.
        let cart = Cart(catalog: makeCatalog(), persistence: InMemoryPersistenceStore())
        XCTAssertEqual(cart.persistenceKey, "cart.lines")
    }

    func testCartAddExistingLineRollbackPreservesQuantity() throws {
        let failing = ToggleableFailingStore()
        failing.failOnSave = false
        let cart = Cart(catalog: makeCatalog(), persistence: failing)
        try cart.add(skuId: "t1", quantity: 2)
        XCTAssertEqual(cart.lines.first?.quantity, 2)

        failing.failOnSave = true
        XCTAssertThrowsError(try cart.add(skuId: "t1", quantity: 3)) { err in
            XCTAssertEqual(err as? CartError, .persistenceFailed)
        }
        // Quantity must roll back to the pre-add value.
        XCTAssertEqual(cart.lines.first?.quantity, 2,
                       "failed accumulating add must leave the prior quantity untouched")
    }

    func testCartUpdateToZeroRollback() throws {
        let failing = ToggleableFailingStore()
        failing.failOnSave = false
        let cart = Cart(catalog: makeCatalog(), persistence: failing)
        try cart.add(skuId: "t1", quantity: 2)

        failing.failOnSave = true
        XCTAssertThrowsError(try cart.update(skuId: "t1", quantity: 0))
        XCTAssertEqual(cart.lines.count, 1,
                       "update-to-zero rollback must preserve the line")
        XCTAssertEqual(cart.lines.first?.quantity, 2)
    }

    func testCartHydrationAfterCrossUserRestart() throws {
        // Simulate a shared-device install across a restart: alice's lines must
        // rehydrate under alice, bob sees empty lines, alice re-hydrated
        // doesn't see bob's lines.
        let store = InMemoryPersistenceStore()
        let catalog = makeCatalog()

        let alice1 = Cart(catalog: catalog, persistence: store, ownerUserId: "alice")
        try alice1.add(skuId: "t1", quantity: 1)
        try alice1.add(skuId: "t2", quantity: 2)

        let bob1 = Cart(catalog: catalog, persistence: store, ownerUserId: "bob")
        try bob1.add(skuId: "t1", quantity: 5)

        // Simulated restart.
        let alice2 = Cart(catalog: catalog, persistence: store, ownerUserId: "alice")
        XCTAssertEqual(alice2.lines.count, 2)
        XCTAssertEqual(alice2.lines.first { $0.sku.id == "t1" }?.quantity, 1)

        let bob2 = Cart(catalog: catalog, persistence: store, ownerUserId: "bob")
        XCTAssertEqual(bob2.lines.count, 1)
        XCTAssertEqual(bob2.lines.first?.quantity, 5)
    }

    func testCartClearRollbackPreservesExactLines() throws {
        let failing = ToggleableFailingStore()
        failing.failOnSave = false
        let cart = Cart(catalog: makeCatalog(), persistence: failing)
        try cart.add(skuId: "t1", quantity: 1)
        try cart.add(skuId: "t2", quantity: 2)

        failing.failOnSave = true
        XCTAssertThrowsError(try cart.clear()) { err in
            XCTAssertEqual(err as? CartError, .persistenceFailed)
        }
        // Lines must be restored in the same order and with the same quantities.
        XCTAssertEqual(cart.lines.count, 2)
        XCTAssertEqual(cart.lines.first { $0.sku.id == "t1" }?.quantity, 1)
        XCTAssertEqual(cart.lines.first { $0.sku.id == "t2" }?.quantity, 2)
    }

    // MARK: - Membership: rollback + boundary tests

    func testMembershipEnrollRollbackOnPersistenceFailure() throws {
        let failing = ToggleableFailingStore()
        failing.failOnSave = true
        let svc = MembershipService(persistence: failing)
        XCTAssertThrowsError(try svc.enroll(userId: "u1", actingUser: admin)) { err in
            XCTAssertEqual(err as? PersistenceError, .encodingFailed,
                           "raw persistence error must surface")
        }
        XCTAssertNil(svc.member("u1"),
                     "in-memory enrollment must roll back so a retry can succeed")
    }

    func testMembershipUpgradeRollbackPreservesPriorTier() throws {
        let failing = ToggleableFailingStore()
        failing.failOnSave = false
        let svc = MembershipService(persistence: failing)
        _ = try svc.enroll(userId: "u1", tier: .bronze, actingUser: admin)

        failing.failOnSave = true
        XCTAssertThrowsError(try svc.upgradeTier(userId: "u1", to: .gold, actingUser: admin))
        XCTAssertEqual(svc.member("u1")?.tier, .bronze,
                       "upgrade must roll back on persistence failure")
    }

    func testMembershipCampaignRollbackOnCreateFailure() throws {
        let failing = ToggleableFailingStore()
        failing.failOnSave = true
        let svc = MembershipService(persistence: failing)
        let c = MarketingCampaign(id: "c1", name: "X", offerDescription: "Y")
        XCTAssertThrowsError(try svc.createCampaign(c, actingUser: admin))
        XCTAssertNil(svc.campaign("c1"),
                     "campaign must roll back on persist failure")
    }

    func testAccruePointsBoundaryOneIsAllowed() throws {
        let svc = MembershipService()
        _ = try svc.enroll(userId: "u1", actingUser: admin)
        try svc.accruePoints(userId: "u1", points: 1, actingUser: admin)
        XCTAssertEqual(svc.member("u1")?.pointsBalance, 1)
    }

    func testRedeemPointsExactBalanceAllowed() throws {
        // Alice self-enrolls (membership allows self-enroll without the
        // .manageMembership permission) so the userId matches her acting id.
        let svc = MembershipService()
        _ = try svc.enroll(userId: alice.id, actingUser: alice)
        try svc.accruePoints(userId: alice.id, points: 50, actingUser: admin)
        XCTAssertNoThrow(try svc.redeemPoints(userId: alice.id, points: 50, actingUser: alice))
        XCTAssertEqual(svc.member(alice.id)?.pointsBalance, 0)
    }

    func testRedeemOverBalanceRejectsBeforeTouchingValue() throws {
        let svc = MembershipService()
        _ = try svc.enroll(userId: alice.id, actingUser: alice)
        try svc.accruePoints(userId: alice.id, points: 10, actingUser: admin)
        XCTAssertThrowsError(try svc.redeemPoints(userId: alice.id, points: 11, actingUser: alice)) { err in
            XCTAssertEqual(err as? MembershipError, .insufficientPoints)
        }
        XCTAssertEqual(svc.member(alice.id)?.pointsBalance, 10,
                       "balance must not change when redeem is rejected")
    }

    // MARK: - Content rollback: exhaustive status matrix

    private func makeContentService() -> (ContentPublishingService, FakeClock,
                                          User, User) {
        let clock = FakeClock()
        let svc = ContentPublishingService(clock: clock, battery: FakeBattery())
        let editor = User(id: "e1", displayName: "Ed", role: .contentEditor)
        let reviewer = User(id: "r1", displayName: "Ri", role: .contentReviewer)
        return (svc, clock, editor, reviewer)
    }

    func testRollbackFromDraftStaysRolledBack() throws {
        let (svc, _, editor, _) = makeContentService()
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "T",
                                tag: TaxonomyTag(), body: "v1",
                                editorId: editor.id, actingUser: editor)
        _ = try svc.edit(id: "c1", body: "v2", editorId: editor.id, actingUser: editor)
        // Still in .draft state — rollback should land on .rolledBack.
        try svc.rollback(id: "c1", actingUser: editor)
        XCTAssertEqual(svc.get("c1")?.status, .rolledBack,
                       "rollback of a draft must not surface to customers")
    }

    func testRollbackFromRejectedStaysRolledBack() throws {
        let (svc, _, editor, reviewer) = makeContentService()
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "T",
                                tag: TaxonomyTag(), body: "v1",
                                editorId: editor.id, actingUser: editor)
        _ = try svc.edit(id: "c1", body: "v2", editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        try svc.reject(id: "c1", reviewer: reviewer)
        try svc.rollback(id: "c1", actingUser: editor)
        XCTAssertEqual(svc.get("c1")?.status, .rolledBack)
    }

    func testRollbackMultipleVersionsPreservesPublishedVisibility() throws {
        let (svc, _, editor, reviewer) = makeContentService()
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "T",
                                tag: TaxonomyTag(), body: "v1",
                                editorId: editor.id, actingUser: editor)
        _ = try svc.edit(id: "c1", body: "v2", editorId: editor.id, actingUser: editor)
        _ = try svc.edit(id: "c1", body: "v3", editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        try svc.approve(id: "c1", reviewer: reviewer)
        // Rollback twice should land at v1 but stay published each time.
        try svc.rollback(id: "c1", actingUser: reviewer)
        XCTAssertEqual(svc.get("c1")?.currentVersion, 2)
        XCTAssertEqual(svc.get("c1")?.status, .published)
        try svc.rollback(id: "c1", actingUser: reviewer)
        XCTAssertEqual(svc.get("c1")?.currentVersion, 1)
        XCTAssertEqual(svc.get("c1")?.status, .published)
    }

    func testPublishedBrowseIncludesRolledBackItem() throws {
        let (svc, _, editor, reviewer) = makeContentService()
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "Advisory",
                                tag: TaxonomyTag(region: .northeast), body: "v1",
                                editorId: editor.id, actingUser: editor)
        _ = try svc.edit(id: "c1", body: "v2", editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        try svc.approve(id: "c1", reviewer: reviewer)
        try svc.rollback(id: "c1", actingUser: reviewer)
        let listed = svc.items(publishedOnly: true)
        XCTAssertTrue(listed.contains { $0.id == "c1" })
        // Taxonomy filter still works post-rollback.
        let filtered = svc.items(filter: TaxonomyTag(region: .northeast),
                                 publishedOnly: true)
        XCTAssertTrue(filtered.contains { $0.id == "c1" })
    }

    // MARK: - ProcessScheduled: multiple items with partial failure

    func testProcessScheduledMultipleItemsPartialFailure() throws {
        /// Persistence store that only fails when the item id embedded in the
        /// key matches `failingItemId`. Lets us exercise "some items publish,
        /// some re-defer" in a single processScheduled call.
        final class SelectiveFailingStore: PersistenceStore {
            let failingItemId: String
            var inner: [String: Data] = [:]
            init(failingItemId: String) { self.failingItemId = failingItemId }
            func save(key: String, data: Data) throws {
                if key == ContentPublishingService.persistencePrefix + failingItemId {
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
                for k in inner.keys where k.hasPrefix(prefix) {
                    inner.removeValue(forKey: k)
                }
            }
        }
        let clock = FakeClock()
        let editor = User(id: "e1", displayName: "Ed", role: .contentEditor)
        let reviewer = User(id: "r1", displayName: "Ri", role: .contentReviewer)
        // Create two items and a failing store — but fail only for "c2".
        // First create them in a non-failing store, then swap stores for the
        // publish tick so c2's scheduled → published persist fails.
        let stagingStore = InMemoryPersistenceStore()
        let staging = ContentPublishingService(clock: clock, battery: FakeBattery(),
                                               persistence: stagingStore)
        for id in ["c1", "c2"] {
            _ = try staging.createDraft(id: id, kind: .travelAdvisory, title: id,
                                        tag: TaxonomyTag(), body: "v1",
                                        editorId: editor.id, actingUser: editor)
            try staging.submitForReview(id: id, actingUser: editor)
            try staging.schedule(id: id, at: clock.now().addingTimeInterval(60),
                                 reviewer: reviewer)
        }
        // Copy the staging data into the selectively-failing store so
        // `processScheduled` hydrates the two scheduled items.
        let failing = SelectiveFailingStore(failingItemId: "c2")
        for (k, v) in (try stagingStore.loadAll(prefix: "")) {
            failing.inner[k] = v
        }
        let svc = ContentPublishingService(clock: clock, battery: FakeBattery(),
                                           persistence: failing)
        clock.advance(by: 120)
        let published = svc.processScheduled()
        XCTAssertEqual(published, ["c1"],
                       "the non-failing item must publish while the failing one is re-deferred")
        XCTAssertEqual(svc.get("c1")?.status, .published)
        XCTAssertEqual(svc.get("c2")?.status, .scheduled,
                       "failing item must roll back to .scheduled")
        XCTAssertEqual(svc.deferredProcessing, ["c2"])
    }

    // MARK: - Seat: snapshot rollback + registerSeat rollback

    func testRegisterSeatRollsBackOnPersistenceFailure() {
        let failing = ToggleableFailingStore()
        failing.failOnSave = true
        let svc = SeatInventoryService(clock: FakeClock(), persistence: failing)
        let seat = SeatKey(trainId: "T1", date: "2024-01-01", segmentId: "A-B",
                           seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(seat)
        // State must not show the seat since its registration never persisted.
        XCTAssertNil(svc.state(seat),
                     "registerSeat must roll back when durable write fails")
        XCTAssertTrue(svc.registeredKeys().isEmpty)
    }

    func testSnapshotPersistenceFailureRollsBack() throws {
        let failing = ToggleableFailingStore()
        failing.failOnSave = false
        let svc = SeatInventoryService(clock: FakeClock(), persistence: failing)
        let seat = SeatKey(trainId: "T1", date: "2024-01-01", segmentId: "A-B",
                           seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(seat)

        failing.failOnSave = true
        XCTAssertThrowsError(try svc.snapshot(date: "2024-01-01"),
                             "snapshot must surface the durability failure")
        // The snapshots table should not advertise a restorable date whose
        // write failed — rollback(to:) must throw unknownSeat.
        XCTAssertThrowsError(try svc.rollback(to: "2024-01-01")) { err in
            XCTAssertEqual(err as? SeatError, .unknownSeat)
        }
    }

    // MARK: - TalentMatching: authorization + rollback

    func testAllNonMatchTalentRolesForbidden() {
        let svc = TalentMatchingService()
        svc.importResume(Resume(id: "r", name: "R", skills: ["swift"],
                                yearsExperience: 1, certifications: []))
        for role in Role.allCases where !RolePolicy.can(role, .matchTalent) {
            let u = User(id: "u_\(role.rawValue)", displayName: "U", role: role)
            XCTAssertThrowsError(try svc.search(TalentSearchCriteria(), by: u),
                                 "role \(role) must be forbidden") { err in
                if case .forbidden(required: let perm) = err as? AuthorizationError {
                    XCTAssertEqual(perm, .matchTalent)
                } else {
                    XCTFail("Expected AuthorizationError.forbidden(.matchTalent)")
                }
            }
        }
    }

    func testImportResumeRollbackRestoresPriorRecord() {
        let failing = ToggleableFailingStore()
        failing.failOnSave = false
        let svc = TalentMatchingService(persistence: failing)
        let v1 = Resume(id: "r1", name: "v1", skills: ["swift"],
                        yearsExperience: 3, certifications: [])
        svc.importResume(v1)

        // Attempt to overwrite with v2 while persistence fails.
        failing.failOnSave = true
        let v2 = Resume(id: "r1", name: "v2", skills: ["kotlin"],
                        yearsExperience: 5, certifications: [])
        svc.importResume(v2)

        // Prior record must be preserved.
        XCTAssertEqual(svc.allResumes().first { $0.id == "r1" }?.name, "v1",
                       "rollback must restore the prior resume when persistence fails")
    }

    func testImportResumeRollbackDropsFirstTimeFailure() {
        let failing = ToggleableFailingStore()
        failing.failOnSave = true
        let svc = TalentMatchingService(persistence: failing)
        svc.importResume(Resume(id: "r1", name: "n", skills: ["swift"],
                                yearsExperience: 2, certifications: []))
        XCTAssertTrue(svc.allResumes().isEmpty,
                      "first-time import failure must not leave the resume in memory")
    }

    // MARK: - CredentialStore: first-install detection

    func testHasAnyCredentialsFlipsAfterEnroll() throws {
        let keychain = InMemoryKeychain()
        let store = KeychainCredentialStore(keychain: keychain)
        XCTAssertFalse(store.hasAnyCredentials())
        try store.enroll(username: "admin", password: "AdminPass!2024",
                         user: User(id: "a1", displayName: "A", role: .administrator))
        XCTAssertTrue(store.hasAnyCredentials())
    }

    func testHasAnyCredentialsReturnsFalseAfterLastRemoval() throws {
        let keychain = InMemoryKeychain()
        let store = KeychainCredentialStore(keychain: keychain)
        try store.enroll(username: "admin", password: "AdminPass!2024",
                         user: User(id: "a1", displayName: "A", role: .administrator))
        try store.remove(username: "admin")
        XCTAssertFalse(store.hasAnyCredentials(),
                       "after removal of the last credential, bootstrap path must reopen")
    }

    func testPasswordPolicyEnforcedOnEnrollment() {
        let keychain = InMemoryKeychain()
        let store = KeychainCredentialStore(keychain: keychain)
        XCTAssertThrowsError(try store.enroll(username: "admin", password: "short",
                                              user: User(id: "a1", displayName: "A",
                                                         role: .administrator))) { err in
            if case .weakPassword = err as? CredentialError { /* expected */ }
            else { XCTFail("Expected CredentialError.weakPassword") }
        }
        XCTAssertFalse(store.hasAnyCredentials(),
                       "rejected enrollment must not count toward bootstrap state")
    }

    // MARK: - RailCommerce composition: user-scoped cart lifecycle

    func testRailCommerceUserCartPersistsAcrossSessions() throws {
        let persistence = InMemoryPersistenceStore()
        let app1 = RailCommerce(persistence: persistence)
        app1.catalog.upsert(SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 1000))
        try app1.cart(forUser: "alice").add(skuId: "t1", quantity: 4)

        // Simulated app restart: fresh RailCommerce on the same persistence.
        let app2 = RailCommerce(persistence: persistence)
        app2.catalog.upsert(SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 1000))
        let rehydrated = app2.cart(forUser: "alice")
        XCTAssertEqual(rehydrated.lines.first?.quantity, 4,
                       "a user's cart must rehydrate on the same device")
    }

    func testRailCommerceBobSessionSeesEmptyCartOnSharedDevice() throws {
        let persistence = InMemoryPersistenceStore()
        let app = RailCommerce(persistence: persistence)
        app.catalog.upsert(SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 1000))

        // Alice signs in and adds items.
        try app.cart(forUser: "alice").add(skuId: "t1", quantity: 3)

        // Bob signs in on the same device — must see an empty cart.
        let bobCart = app.cart(forUser: "bob")
        XCTAssertTrue(bobCart.isEmpty,
                      "Bob's cart must not inherit Alice's lines on a shared device")
    }

    // MARK: - Back-compat: USAddress with no ownerUserId stays accessible via legacy APIs

    func testLegacyAddressRemainsAccessibleViaUnscopedAPIs() throws {
        let book = AddressBook()
        let legacy = USAddress(id: "legacy", recipient: "L", line1: "1",
                               city: "NYC", state: .NY, zip: "10001")
        _ = try book.save(legacy)
        XCTAssertEqual(book.addresses.map { $0.id }, ["legacy"],
                       "unscoped addresses must still be visible via the legacy property")
        XCTAssertNotNil(book.defaultAddress,
                        "unscoped default must still resolve via the legacy property")
    }

    // MARK: - Durability observability

    func testSeatSweepRecordsLastSweepErrorOnFailure() throws {
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
            func delete(key: String) throws { inner.removeValue(forKey: key) }
            func deleteAll(prefix: String) throws {
                if failOnSave { throw PersistenceError.encodingFailed }
                for k in inner.keys where k.hasPrefix(prefix) { inner.removeValue(forKey: k) }
            }
        }
        let store = ToggleStore()
        let clock = FakeClock()
        let svc = SeatInventoryService(clock: clock, persistence: store)
        let seat = SeatKey(trainId: "T1", date: "2024-01-01", segmentId: "A-B",
                           seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(seat)
        let customer = User(id: "c1", displayName: "C", role: .customer)
        _ = try svc.reserve(seat, holderId: "c1", actingUser: customer)
        XCTAssertNil(svc.lastSweepError,
                     "no sweep has failed yet; observability hook must be nil")

        clock.advance(by: 16 * 60)
        store.failOnSave = true
        _ = svc.state(seat)  // triggers sweep
        XCTAssertNotNil(svc.lastSweepError,
                        "a failed sweep must surface via lastSweepError for callers")
        XCTAssertEqual(svc.lastSweepError as? SeatError, .persistenceFailed,
                       "sweep must surface the typed domain error, not swallow it")
    }

    func testSeatSweepClearsLastSweepErrorOnSubsequentSuccess() throws {
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
            func delete(key: String) throws { inner.removeValue(forKey: key) }
            func deleteAll(prefix: String) throws {
                if failOnSave { throw PersistenceError.encodingFailed }
                for k in inner.keys where k.hasPrefix(prefix) { inner.removeValue(forKey: k) }
            }
        }
        let store = ToggleStore()
        let clock = FakeClock()
        let svc = SeatInventoryService(clock: clock, persistence: store)
        let seat = SeatKey(trainId: "T1", date: "2024-01-01", segmentId: "A-B",
                           seatClass: .economy, seatNumber: "1A")
        svc.registerSeat(seat)
        let customer = User(id: "c1", displayName: "C", role: .customer)
        _ = try svc.reserve(seat, holderId: "c1", actingUser: customer)

        clock.advance(by: 16 * 60)
        store.failOnSave = true
        _ = svc.state(seat)
        XCTAssertNotNil(svc.lastSweepError)

        // Storage heals; the next sweep that actually mutates must clear the error.
        // Reserve again (as customer c1 — identity-binding requires holder ==
        // actingUser.id for non-`.processTransaction` roles), then advance the
        // clock past the new hold, then read to sweep.
        store.failOnSave = false
        _ = try svc.reserve(seat, holderId: "c1", actingUser: customer)
        clock.advance(by: 16 * 60)
        _ = svc.state(seat)
        XCTAssertNil(svc.lastSweepError,
                     "a successful sweep must clear the durability observability flag")
    }

    func testProcessScheduledExposesPerItemErrors() throws {
        final class SelectiveStore: PersistenceStore {
            let failingItemId: String
            var inner: [String: Data] = [:]
            init(failingItemId: String) { self.failingItemId = failingItemId }
            func save(key: String, data: Data) throws {
                if key == ContentPublishingService.persistencePrefix + failingItemId {
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
                for k in inner.keys where k.hasPrefix(prefix) {
                    inner.removeValue(forKey: k)
                }
            }
        }
        let clock = FakeClock()
        let editor = User(id: "e1", displayName: "Ed", role: .contentEditor)
        let reviewer = User(id: "r1", displayName: "Ri", role: .contentReviewer)
        let staging = InMemoryPersistenceStore()
        let staged = ContentPublishingService(clock: clock, battery: FakeBattery(),
                                              persistence: staging)
        for id in ["c1", "c2"] {
            _ = try staged.createDraft(id: id, kind: .travelAdvisory, title: id,
                                       tag: TaxonomyTag(), body: "v1",
                                       editorId: editor.id, actingUser: editor)
            try staged.submitForReview(id: id, actingUser: editor)
            try staged.schedule(id: id, at: clock.now().addingTimeInterval(60),
                                reviewer: reviewer)
        }
        let failing = SelectiveStore(failingItemId: "c2")
        for (k, v) in try staging.loadAll(prefix: "") { failing.inner[k] = v }

        let svc = ContentPublishingService(clock: clock, battery: FakeBattery(),
                                           persistence: failing)
        clock.advance(by: 120)
        let published = svc.processScheduled()

        XCTAssertEqual(published, ["c1"])
        XCTAssertEqual(Array(svc.lastProcessScheduledErrors.keys), ["c2"],
                       "lastProcessScheduledErrors must expose exactly the failed item ids")
        XCTAssertTrue(svc.lastProcessScheduledErrors["c2"] is ContentError,
                      "the per-item error must be the typed domain error")
    }

    func testProcessScheduledClearsErrorsOnSuccessfulTick() throws {
        let store = InMemoryPersistenceStore()
        let clock = FakeClock()
        let editor = User(id: "e1", displayName: "Ed", role: .contentEditor)
        let reviewer = User(id: "r1", displayName: "Ri", role: .contentReviewer)
        let svc = ContentPublishingService(clock: clock, battery: FakeBattery(),
                                           persistence: store)
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "t",
                                tag: TaxonomyTag(), body: "v1",
                                editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        try svc.schedule(id: "c1", at: clock.now().addingTimeInterval(60),
                         reviewer: reviewer)
        clock.advance(by: 120)
        _ = svc.processScheduled()
        XCTAssertTrue(svc.lastProcessScheduledErrors.isEmpty,
                      "a successful tick must leave the error map empty")
    }
}
