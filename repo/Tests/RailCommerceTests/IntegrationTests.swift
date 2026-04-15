import XCTest
@testable import RailCommerce

/// End-to-end flows that exercise several services together to verify the prompt's
/// cross-cutting requirements.
final class IntegrationTests: XCTestCase {

    // MARK: Full purchase flow — browse → cart → promotion → checkout → verify → after-sales
    func testCustomerCompletesPurchaseAndReturnsWithRefund() throws {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_704_103_200)) // Mon 2024-01-01 10:00Z
        let keychain = InMemoryKeychain()
        let camera = FakeCamera(granted: true)
        let battery = FakeBattery()
        let app = RailCommerce(clock: clock, keychain: keychain, camera: camera, battery: battery)

        // Administrator seeds catalog
        app.catalog.upsert(SKU(id: "t1", kind: .ticket, title: "NE Express",
                               priceCents: 5_000, tag: TaxonomyTag(region: .northeast, theme: .scenic, riderType: .tourist)))
        app.catalog.upsert(SKU(id: "m1", kind: .merchandise, title: "Travel Mug", priceCents: 1_500))
        app.catalog.upsert(SKU(id: "combo", kind: .bundle, title: "Scenic Combo",
                               priceCents: 6_000, bundleChildren: ["t1", "m1"]))

        // Customer browses by taxonomy
        let browsed = app.catalog.filter(TaxonomyTag(region: .northeast))
        XCTAssertEqual(browsed.map { $0.id }, ["t1"])

        // Customer builds cart and receives bundle suggestion
        let cart = Cart(catalog: app.catalog)
        try cart.add(skuId: "t1", quantity: 1)
        let suggestion = cart.bundleSuggestions().first
        XCTAssertEqual(suggestion?.bundleId, "combo")

        // Customer saves address, chooses shipping
        let address = USAddress(id: "home", recipient: "Alice", line1: "1 Main",
                                city: "NYC", state: .NY, zip: "10001", isDefault: true)
        try app.addressBook.save(address)
        let shipping = ShippingTemplate(id: "std", name: "Standard", feeCents: 500, etaDays: 3)

        // Promotion pipeline: 1 percent-off, 1 amount-off, 1 free-shipping
        let discounts = [
            Discount(code: "PCT10", kind: .percentOff, magnitude: 10, priority: 1),
            Discount(code: "AMT200", kind: .amountOff, magnitude: 200, priority: 2),
            Discount(code: "SHIPFREE", kind: .freeShipping, magnitude: 0, priority: 3)
        ]

        // Checkout submits idempotently
        let snap = try app.checkout.submit(orderId: "O-1001", userId: "C1", cart: cart,
                                           discounts: discounts,
                                           address: app.addressBook.defaultAddress!,
                                           shipping: shipping, invoiceNotes: "Gift")
        XCTAssertTrue(snap.promotion.freeShipping)
        XCTAssertEqual(snap.totalCents, snap.promotion.lineExplanations
                        .reduce(0) { $0 + $1.discountedCents })

        // Hash stored, snapshot verifies
        XCTAssertNotNil(app.checkout.storedHash(for: "O-1001"))
        XCTAssertNoThrow(try app.checkout.verify(snap))

        // Duplicate submission within 10 s is blocked
        XCTAssertThrowsError(try app.checkout.submit(orderId: "O-1001", userId: "C1", cart: cart,
                                                     discounts: discounts, address: address,
                                                     shipping: shipping, invoiceNotes: "Gift"))

        // Customer opens refund-only after-sales request
        let rma = AfterSalesRequest(id: "R-1", orderId: "O-1001", kind: .refundOnly,
                                    reason: .defective, createdAt: clock.now(),
                                    serviceDate: clock.now(), amountCents: 1_500)
        _ = try app.afterSales.open(rma)

        // CSR responds within SLA
        clock.advance(by: 60 * 60) // 1h later
        try app.afterSales.respond(id: "R-1")
        let sla = app.afterSales.sla(for: "R-1")!
        XCTAssertFalse(sla.firstResponseBreached)

        // Without dispute, automation auto-approves after 48h because amount < $25
        clock.advance(by: 48 * 3600)
        let changed = app.afterSales.runAutomation()
        XCTAssertEqual(changed, ["R-1"])
        XCTAssertEqual(app.afterSales.get("R-1")?.status, .autoApproved)

        // Notifications were posted through the closed-loop bus
        XCTAssertTrue(app.notifications.events.contains("afterSales.opened:R-1"))
        XCTAssertTrue(app.notifications.events.contains("afterSales.autoApproved:R-1"))
    }

    // MARK: Sales Agent reserves and confirms seats atomically with rollback on failure.
    func testSalesAgentReservationAtomicity() throws {
        let clock = FakeClock()
        let svc = SeatInventoryService(clock: clock)
        let a = SeatKey(trainId: "T1", date: "2024-01-02", segmentId: "S1",
                        seatClass: .economy, seatNumber: "1A")
        let b = SeatKey(trainId: "T1", date: "2024-01-02", segmentId: "S1",
                        seatClass: .economy, seatNumber: "1B")
        svc.registerSeat(a)
        svc.registerSeat(b)
        svc.snapshot(date: "2024-01-02")

        // Reserve both in an atomic block but force failure.
        XCTAssertThrowsError(try svc.atomic {
            _ = try svc.reserve(a, holderId: "H")
            _ = try svc.reserve(b, holderId: "H")
            throw SeatError.notAvailable
        })
        XCTAssertEqual(svc.state(a), .available)
        XCTAssertEqual(svc.state(b), .available)

        // Proper success path confirms.
        try svc.reserve(a, holderId: "H")
        try svc.confirm(a, holderId: "H")
        XCTAssertEqual(svc.state(a), .sold)

        // Audit rollback to snapshot restores availability.
        try svc.rollback(to: "2024-01-02")
        XCTAssertEqual(svc.state(a), .available)
    }

    // MARK: Content Editor + Reviewer two-step workflow with scheduled publishing.
    func testEditorReviewerPublishingAndScheduling() throws {
        let clock = FakeClock()
        let battery = FakeBattery()
        let svc = ContentPublishingService(clock: clock, battery: battery)
        let editor = User(id: "e1", displayName: "Eve", role: .contentEditor)
        let reviewer = User(id: "r1", displayName: "Rita", role: .contentReviewer)

        _ = svc.createDraft(id: "adv-1", kind: .travelAdvisory, title: "Snow Delay",
                            tag: TaxonomyTag(region: .northeast), body: "v1", editorId: editor.id)
        // Editor cannot publish directly; reviewer must approve.
        XCTAssertThrowsError(try svc.approve(id: "adv-1", reviewer: editor))

        _ = try svc.edit(id: "adv-1", body: "v2", editorId: editor.id)
        try svc.submitForReview(id: "adv-1")
        try svc.schedule(id: "adv-1", at: clock.now().addingTimeInterval(30), reviewer: reviewer)

        // Battery drops — scheduler defers.
        battery.isLowPowerMode = true
        clock.advance(by: 60)
        XCTAssertTrue(svc.processScheduled().isEmpty)
        XCTAssertEqual(svc.deferredProcessing, ["adv-1"])

        // Battery recovers — publishes.
        battery.isLowPowerMode = false
        XCTAssertEqual(svc.processScheduled(), ["adv-1"])
        XCTAssertEqual(svc.get("adv-1")?.status, .published)
    }

    // MARK: CSR messaging flow — queued, masked, filtered, drained.
    func testStaffMessagingAcrossFiltersAndQueue() throws {
        let clock = FakeClock()
        let svc = MessagingService(clock: clock)

        // Contact masking applied when content is safe.
        let masked = try svc.enqueue(id: "m1", from: "csr1", to: "agent2",
                                     body: "reach the rider at rider@mail.com or 555 222 3333")
        XCTAssertTrue(masked.body.contains("****@****"))
        // Last 4 digits of 555 222 3333 are preserved: ***-***-3333
        XCTAssertTrue(masked.body.contains("***-***-3333"))

        // Sensitive data blocked.
        XCTAssertThrowsError(try svc.enqueue(id: "m2", from: "csr1", to: "agent2",
                                             body: "SSN 111-22-3333"))

        // Large attachment rejected.
        let huge = MessageAttachment(id: "big", kind: .pdf,
                                     sizeBytes: MessagingService.maxAttachmentBytes + 1)
        XCTAssertThrowsError(try svc.enqueue(id: "m3", from: "csr1", to: "agent2",
                                             body: "hi", attachments: [huge]))

        // Queue drains after offline sync.
        clock.advance(by: 10)
        let delivered = svc.drainQueue()
        XCTAssertEqual(delivered.count, 1)
        XCTAssertTrue(svc.queue.isEmpty)
    }

    // MARK: Talent matching end-to-end with Boolean filter and weights.
    func testTalentMatchingExplainableRanking() {
        let svc = TalentMatchingService()
        svc.importResume(Resume(id: "r1", name: "A", skills: ["swift", "uikit"],
                                yearsExperience: 6, certifications: ["railSafety"]))
        svc.importResume(Resume(id: "r2", name: "B", skills: ["swift"],
                                yearsExperience: 2, certifications: []))
        svc.importResume(Resume(id: "r3", name: "C", skills: ["python"],
                                yearsExperience: 10, certifications: ["railSafety"]))

        let criteria = TalentSearchCriteria(
            wantedSkills: ["swift", "uikit"],
            wantedCertifications: ["railSafety"],
            desiredYears: 5,
            filter: .or(.hasSkill("swift"), .hasCertification("railSafety"))
        )
        let matches = svc.search(criteria)
        XCTAssertEqual(matches.first?.resumeId, "r1")
        XCTAssertTrue(matches.first?.explanation.contains("skills=100%") ?? false)

        // Saved search persists and can be recalled.
        let saved = SavedSearch(id: "hot", name: "Swift+Safety",
                                wantedSkills: ["swift"], wantedCertifications: ["railSafety"],
                                desiredYears: 5)
        svc.saveSearch(saved)
        XCTAssertEqual(svc.savedSearch("hot"), saved)

        // Bulk tag exercised.
        svc.bulkTag(ids: ["r1", "r2"], add: "priority")
        XCTAssertTrue(svc.allResumes().first { $0.id == "r1" }!.tags.contains("priority"))
    }

    // MARK: Attachments — sandbox + 30-day cleanup integration.
    func testAttachmentsLifecycleAndCleanup() throws {
        let clock = FakeClock()
        let svc = AttachmentService(clock: clock)
        _ = try svc.save(id: "a1", data: Data([0, 1]), kind: .jpeg)
        _ = try svc.save(id: "a2", data: Data([2, 3]), kind: .pdf)
        XCTAssertEqual(svc.all().count, 2)

        clock.advance(by: 31 * 86_400)
        let removed = svc.runRetentionSweep()
        XCTAssertEqual(removed.sorted(), ["a1", "a2"])
        XCTAssertTrue(svc.all().isEmpty)
    }

    // MARK: App lifecycle integration — cold start + memory warning eviction.
    func testAppLifecycleColdStartAndMemoryWarning() {
        let svc = AppLifecycleService(clock: FakeClock())
        let begin = Date()
        XCTAssertTrue(svc.markColdStart(begin: begin, end: begin.addingTimeInterval(1.2)))
        svc.cache(key: "img1", data: Data([9]))
        svc.scheduleDecode("img1")
        svc.handleMemoryWarning()
        XCTAssertEqual(svc.cacheEvictions, 1)
        XCTAssertEqual(svc.deferredDecodes, 1)
        XCTAssertNil(svc.cached("img1"))
    }

    // MARK: Role-based access integration — admin bypasses, editor blocked from publish.
    func testRoleBasedAccessIntegration() throws {
        let clock = FakeClock()
        let svc = ContentPublishingService(clock: clock, battery: FakeBattery())
        let admin = User(id: "a1", displayName: "Admin", role: .administrator)
        let editor = User(id: "e1", displayName: "E", role: .contentEditor)

        _ = svc.createDraft(id: "c1", kind: .onboardOffer, title: "Offer",
                            tag: TaxonomyTag(), body: "v1", editorId: editor.id)
        try svc.submitForReview(id: "c1")

        // Administrator may also approve (policy allows publishContent).
        XCTAssertTrue(RolePolicy.can(.administrator, .publishContent))
        try svc.approve(id: "c1", reviewer: admin)
        XCTAssertEqual(svc.get("c1")?.status, .published)

        // Editor may not publish content per policy.
        XCTAssertFalse(RolePolicy.can(.contentEditor, .publishContent))
    }
}
