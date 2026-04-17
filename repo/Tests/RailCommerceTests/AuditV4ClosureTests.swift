import XCTest
@testable import RailCommerce

/// Regression tests for v4 audit findings:
///   - After-sales `dispute` object-level ownership (High / Fail → Pass)
///   - Content publishing power + inactivity gating (High / Partial Fail → Pass)
///   - Reference-aware attachment retention (Medium / Partial Fail → Pass)
///
/// Each test locks in the fix so the prior defect cannot silently regress.
final class AuditV4ClosureTests: XCTestCase {

    // MARK: - Issue 1: after-sales dispute ownership

    private let alice = User(id: "alice", displayName: "Alice", role: .customer)
    private let bob = User(id: "bob", displayName: "Bob", role: .customer)
    private let csr = User(id: "csr", displayName: "CSR", role: .customerService)
    private let admin = User(id: "admin", displayName: "Admin", role: .administrator)

    private func afterSalesSetup() -> AfterSalesService {
        AfterSalesService(clock: FakeClock(),
                          camera: FakeCamera(granted: true),
                          notifier: LocalNotificationBus())
    }

    /// Regression: a customer with `.manageAfterSales` must NOT be able to dispute
    /// another customer's request — even though the function-level permission check
    /// passes, the object-level ownership check rejects them.
    func testCustomerCannotDisputeAnotherUsersRequest() throws {
        let svc = afterSalesSetup()
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind, createdAt: Date(),
                                    serviceDate: Date(), amountCents: 500)
        try svc.open(req, actingUser: alice)   // alice owns R1
        XCTAssertThrowsError(try svc.dispute(id: "R1", actingUser: bob)) { err in
            XCTAssertEqual(err as? AfterSalesError, .orderNotOwned,
                           "bob must not be able to dispute alice's request")
        }
        // Alice's request must still be un-disputed — attempted mutation had no effect.
        XCTAssertNil(svc.get("R1")?.disputedAt)
    }

    func testCustomerCanDisputeOwnRequest() throws {
        let svc = afterSalesSetup()
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind, createdAt: Date(),
                                    serviceDate: Date(), amountCents: 500)
        try svc.open(req, actingUser: alice)
        XCTAssertNoThrow(try svc.dispute(id: "R1", actingUser: alice))
        XCTAssertNotNil(svc.get("R1")?.disputedAt)
    }

    func testCSRCanDisputeAnyRequest() throws {
        let svc = afterSalesSetup()
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind, createdAt: Date(),
                                    serviceDate: Date(), amountCents: 500)
        try svc.open(req, actingUser: alice)
        XCTAssertNoThrow(try svc.dispute(id: "R1", actingUser: csr))
        XCTAssertNotNil(svc.get("R1")?.disputedAt)
    }

    func testAdminCanDisputeAnyRequest() throws {
        let svc = afterSalesSetup()
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind, createdAt: Date(),
                                    serviceDate: Date(), amountCents: 500)
        try svc.open(req, actingUser: alice)
        XCTAssertNoThrow(try svc.dispute(id: "R1", actingUser: admin))
    }

    func testDisputeRequiresManageAfterSalesPermission() throws {
        let svc = afterSalesSetup()
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind, createdAt: Date(),
                                    serviceDate: Date(), amountCents: 500)
        try svc.open(req, actingUser: alice)
        let editor = User(id: "editor", displayName: "E", role: .contentEditor)
        // Content editor lacks .manageAfterSales — function-level check fails first.
        XCTAssertThrowsError(try svc.dispute(id: "R1", actingUser: editor)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden") }
        }
    }

    // MARK: - Issue 2: power + inactivity gating for scheduled publishing

    private func publishingSetup(battery: FakeBattery) ->
        (ContentPublishingService, FakeClock, String, User, User) {
        let clock = FakeClock()
        let svc = ContentPublishingService(clock: clock, battery: battery)
        let editor = User(id: "editor", displayName: "E", role: .contentEditor)
        let reviewer = User(id: "reviewer", displayName: "R", role: .contentReviewer)
        let id = "C1"
        _ = try! svc.createDraft(id: id, kind: .travelAdvisory, title: "T",
                                 tag: TaxonomyTag(), body: "v1",
                                 editorId: editor.id, actingUser: editor)
        try! svc.submitForReview(id: id, actingUser: editor)
        try! svc.schedule(id: id, at: clock.now().addingTimeInterval(10), reviewer: reviewer)
        clock.advance(by: 60)
        return (svc, clock, id, editor, reviewer)
    }

    /// When the device is neither on power nor in the user-inactive state, heavy
    /// scheduled publishing must be deferred — even if the battery isn't low.
    func testProcessScheduledDefersWhenNotOnPowerAndUserActive() throws {
        let battery = FakeBattery(level: 0.9, isLowPowerMode: false,
                                  isCharging: false, isUserInactive: false)
        let (svc, _, id, _, _) = publishingSetup(battery: battery)
        let published = svc.processScheduled()
        XCTAssertTrue(published.isEmpty,
                      "Publishing must defer when user is active and device is not on power")
        XCTAssertEqual(svc.deferredProcessing, [id])
        XCTAssertNotEqual(svc.get(id)?.status, .published)
    }

    /// When the device is on external power, heavy work runs even if the user is active.
    func testProcessScheduledPublishesWhenOnExternalPower() throws {
        let battery = FakeBattery(level: 0.4, isLowPowerMode: false,
                                  isCharging: true, isUserInactive: false)
        let (svc, _, id, _, _) = publishingSetup(battery: battery)
        let published = svc.processScheduled()
        XCTAssertEqual(published, [id])
        XCTAssertTrue(svc.deferredProcessing.isEmpty)
        XCTAssertEqual(svc.get(id)?.status, .published)
    }

    /// When the device is off power but the user is inactive, heavy work runs.
    func testProcessScheduledPublishesWhenUserInactive() throws {
        let battery = FakeBattery(level: 0.8, isLowPowerMode: false,
                                  isCharging: false, isUserInactive: true)
        let (svc, _, id, _, _) = publishingSetup(battery: battery)
        let published = svc.processScheduled()
        XCTAssertEqual(published, [id])
    }

    /// Low Power Mode always defers regardless of other state.
    func testProcessScheduledDefersInLowPowerMode() throws {
        let battery = FakeBattery(level: 1.0, isLowPowerMode: true,
                                  isCharging: true, isUserInactive: true)
        let (svc, _, id, _, _) = publishingSetup(battery: battery)
        XCTAssertTrue(svc.processScheduled().isEmpty)
        XCTAssertEqual(svc.deferredProcessing, [id])
    }

    /// Below 20% battery without a charger also defers — low battery is a hard floor.
    func testProcessScheduledDefersBelow20PercentAndNotCharging() throws {
        let battery = FakeBattery(level: 0.1, isLowPowerMode: false,
                                  isCharging: false, isUserInactive: true)
        let (svc, _, id, _, _) = publishingSetup(battery: battery)
        XCTAssertTrue(svc.processScheduled().isEmpty)
        XCTAssertEqual(svc.deferredProcessing, [id])
    }

    // MARK: - Issue 3: reference-aware attachment retention

    /// An aged attachment that is still referenced by a delivered message must NOT
    /// be purged — only the truly-unreferenced one goes.
    func testRetentionSweepSkipsAttachmentsReferencedByMessaging() throws {
        let clock = FakeClock()
        let battery = FakeBattery()
        let app = RailCommerce(clock: clock, battery: battery)
        let csr = User(id: "csr", displayName: "C", role: .customerService)

        _ = try app.attachments.save(id: "kept", data: Data([1]), kind: .jpeg)
        _ = try app.attachments.save(id: "gone", data: Data([2]), kind: .png)

        // Attach "kept" to a delivered staff message so it's live-referenced.
        let liveAttachment = MessageAttachment(id: "kept", kind: .jpeg, sizeBytes: 1)
        _ = try app.messaging.enqueue(id: "m1", from: csr.id, to: "agent2",
                                       body: "see attached", attachments: [liveAttachment],
                                       actingUser: csr)
        _ = app.messaging.drainQueue()

        // Advance past the 30-day retention window.
        clock.advance(by: 31 * 86_400)
        let removed = app.attachments.runRetentionSweep()

        XCTAssertEqual(removed, ["gone"], "only the unreferenced aged attachment should be purged")
        XCTAssertNotNil(try? app.attachments.get("kept"),
                        "referenced attachment must survive the sweep even when aged")
    }

    /// An aged attachment referenced by an after-sales photo proof must not be purged.
    /// Built directly from service primitives (not the `RailCommerce` container) so
    /// the test does not need to stand up a full checkout + ownership pipeline.
    func testRetentionSweepSkipsAttachmentsReferencedByAfterSales() throws {
        let clock = FakeClock()
        let store = InMemoryPersistenceStore()
        let fileStore = InMemoryFileStore()
        let attachments = AttachmentService(clock: clock, persistence: store,
                                            fileStore: fileStore)
        let customer = User(id: "c1", displayName: "C", role: .customer)
        let afterSales = AfterSalesService(clock: clock,
                                           camera: FakeCamera(granted: true),
                                           notifier: LocalNotificationBus(),
                                           persistence: store)
        // Register the after-sales reference resolver manually — the same wiring
        // that `RailCommerce.init` performs in production.
        attachments.registerReferenceResolver { [weak afterSales] in
            afterSales?.referencedAttachmentIds() ?? []
        }

        _ = try attachments.save(id: "photo", data: Data([1, 2, 3]), kind: .jpeg)
        _ = try attachments.save(id: "orphan", data: Data([4, 5, 6]), kind: .png)

        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .returnAndRefund,
                                    reason: .defective, createdAt: clock.now(),
                                    serviceDate: clock.now(), amountCents: 500,
                                    photoAttachmentIds: ["photo"])
        _ = try afterSales.open(req, actingUser: customer)

        clock.advance(by: 31 * 86_400)
        let removed = attachments.runRetentionSweep()

        XCTAssertEqual(removed, ["orphan"])
        XCTAssertNotNil(try? attachments.get("photo"))
    }

    /// An aged attachment referenced by content media must not be purged.
    func testRetentionSweepSkipsAttachmentsReferencedByContent() throws {
        let clock = FakeClock()
        let battery = FakeBattery()
        let app = RailCommerce(clock: clock, battery: battery)
        let editor = User(id: "editor", displayName: "E", role: .contentEditor)

        _ = try app.attachments.save(id: "media", data: Data([9]), kind: .jpeg)
        _ = try app.attachments.save(id: "orphan", data: Data([0]), kind: .pdf)

        let media = MediaReference(id: "m1", kind: .jpeg, caption: "cover",
                                   attachmentId: "media")
        _ = try app.publishing.createDraft(id: "A1", kind: .travelAdvisory,
                                            title: "T", tag: TaxonomyTag(),
                                            body: "body", mediaRefs: [media],
                                            editorId: editor.id, actingUser: editor)

        clock.advance(by: 31 * 86_400)
        let removed = app.attachments.runRetentionSweep()

        XCTAssertEqual(removed, ["orphan"])
        XCTAssertNotNil(try? app.attachments.get("media"))
    }

    /// Removing the last reference to a previously-kept attachment and re-sweeping
    /// must now purge it — confirming the reference-aware sweep is dynamic, not
    /// a permanent whitelist.
    func testAttachmentBecomesEligibleOnceReferenceIsRemoved() throws {
        let clock = FakeClock()
        let attachments = AttachmentService(clock: clock)
        // Mutable resolver state: initially references "kept", then drops it.
        var liveIds: Set<String> = ["kept"]
        attachments.registerReferenceResolver { liveIds }

        _ = try attachments.save(id: "kept", data: Data([1]), kind: .jpeg)
        clock.advance(by: 31 * 86_400)

        // While still referenced → not swept.
        XCTAssertTrue(attachments.runRetentionSweep().isEmpty,
                      "attachment must survive sweep while referenced")
        XCTAssertNotNil(try? attachments.get("kept"))

        // Last reference removed → now eligible.
        liveIds.removeAll()
        XCTAssertEqual(attachments.runRetentionSweep(), ["kept"],
                       "attachment must be swept once its last reference is removed")
    }

    /// A recent attachment is never purged, referenced or not — age is still a gate.
    func testRetentionSweepKeepsRecentAttachmentsEvenWhenUnreferenced() throws {
        let clock = FakeClock()
        let battery = FakeBattery()
        let app = RailCommerce(clock: clock, battery: battery)
        _ = try app.attachments.save(id: "fresh", data: Data([1]), kind: .jpeg)
        clock.advance(by: 15 * 86_400)   // 15 days, well under 30
        XCTAssertTrue(app.attachments.runRetentionSweep().isEmpty)
        XCTAssertNotNil(try? app.attachments.get("fresh"))
    }
}
