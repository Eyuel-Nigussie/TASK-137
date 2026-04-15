import XCTest
@testable import RailCommerce

final class AfterSalesServiceTests: XCTestCase {
    private func setup(granted: Bool = true) -> (AfterSalesService, FakeClock, LocalNotificationBus, FakeCamera) {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_704_103_200)) // 2024-01-01 10:00 UTC
        let bus = LocalNotificationBus()
        let cam = FakeCamera(granted: granted)
        let service = AfterSalesService(clock: clock, camera: cam, notifier: bus)
        return (service, clock, bus, cam)
    }

    private func request(kind: AfterSalesKind, amount: Int = 1_000,
                         created: Date = Date(timeIntervalSince1970: 1_704_103_200),
                         service: Date? = nil, photos: [String] = []) -> AfterSalesRequest {
        AfterSalesRequest(id: UUID().uuidString, orderId: "O1", kind: kind, reason: .defective,
                          createdAt: created,
                          serviceDate: service ?? created,
                          amountCents: amount, photoAttachmentIds: photos)
    }

    func testOpenRefundOnlyWithoutPhoto() throws {
        let (svc, _, bus, _) = setup()
        let req = request(kind: .refundOnly)
        let saved = try svc.open(req)
        XCTAssertEqual(saved.status, .pending)
        XCTAssertEqual(bus.events.first, "afterSales.opened:\(req.id)")
    }

    func testOpenReturnRequiresPhoto() {
        let (svc, _, _, _) = setup()
        let req = request(kind: .returnAndRefund)
        XCTAssertThrowsError(try svc.open(req)) { err in
            XCTAssertEqual(err as? AfterSalesError, .missingPhoto)
        }
    }

    func testOpenExchangeWithoutCameraDenied() {
        let (svc, _, _, _) = setup(granted: false)
        let req = request(kind: .exchange)
        XCTAssertThrowsError(try svc.open(req)) { err in
            XCTAssertEqual(err as? AfterSalesError, .cameraDenied)
        }
    }

    func testOpenExchangeWithPhotoSucceeds() throws {
        let (svc, _, _, _) = setup()
        let req = request(kind: .exchange, photos: ["att1"])
        let saved = try svc.open(req)
        XCTAssertFalse(saved.photoAttachmentIds.isEmpty)
    }

    func testRespondSetsFirstResponse() throws {
        let (svc, clock, bus, _) = setup()
        let req = request(kind: .refundOnly)
        try svc.open(req)
        clock.advance(by: 3600)
        try svc.respond(id: req.id)
        let r = svc.get(req.id)!
        XCTAssertNotNil(r.firstResponseAt)
        XCTAssertEqual(r.status, .awaitingCustomer)
        XCTAssertTrue(bus.events.contains("afterSales.firstResponse:\(req.id)"))
    }

    func testRespondNotFound() {
        let (svc, _, _, _) = setup()
        XCTAssertThrowsError(try svc.respond(id: "missing")) { err in
            XCTAssertEqual(err as? AfterSalesError, .notFound)
        }
    }

    func testRespondAlreadyClosed() throws {
        let (svc, _, _, _) = setup()
        let req = request(kind: .refundOnly)
        try svc.open(req)
        try svc.close(id: req.id)
        XCTAssertThrowsError(try svc.respond(id: req.id)) { err in
            XCTAssertEqual(err as? AfterSalesError, .alreadyClosed)
        }
    }

    func testApproveRejectDisputeClose() throws {
        let (svc, _, bus, _) = setup()
        let req = request(kind: .refundOnly)
        try svc.open(req)
        try svc.approve(id: req.id)
        XCTAssertEqual(svc.get(req.id)?.status, .approved)
        try svc.reject(id: req.id)
        XCTAssertEqual(svc.get(req.id)?.status, .rejected)
        try svc.dispute(id: req.id)
        XCTAssertNotNil(svc.get(req.id)?.disputedAt)
        try svc.close(id: req.id)
        XCTAssertEqual(svc.get(req.id)?.status, .closed)
        XCTAssertTrue(bus.events.contains("afterSales.approved:\(req.id)"))
        XCTAssertTrue(bus.events.contains("afterSales.rejected:\(req.id)"))
        XCTAssertTrue(bus.events.contains("afterSales.disputed:\(req.id)"))
        XCTAssertTrue(bus.events.contains("afterSales.closed:\(req.id)"))
    }

    func testApproveNotFound() {
        let (svc, _, _, _) = setup()
        XCTAssertThrowsError(try svc.approve(id: "x"))
        XCTAssertThrowsError(try svc.reject(id: "x"))
        XCTAssertThrowsError(try svc.dispute(id: "x"))
        XCTAssertThrowsError(try svc.close(id: "x"))
    }

    func testSLAComputed() throws {
        let (svc, _, _, _) = setup()
        let req = request(kind: .refundOnly)
        try svc.open(req)
        let sla = svc.sla(for: req.id)!
        XCTAssertFalse(sla.firstResponseBreached)
        XCTAssertFalse(sla.resolutionBreached)
    }

    func testSLABreachesWhenLate() throws {
        let (svc, clock, _, _) = setup()
        let req = request(kind: .refundOnly)
        try svc.open(req)
        clock.advance(by: 60 * 60 * 24 * 5) // 5 days later
        let sla = svc.sla(for: req.id)!
        XCTAssertTrue(sla.firstResponseBreached)
        XCTAssertTrue(sla.resolutionBreached)
    }

    func testSLAForUnknown() {
        let (svc, _, _, _) = setup()
        XCTAssertNil(svc.sla(for: "missing"))
    }

    func testAutoApprovalRule() throws {
        let (svc, clock, bus, _) = setup()
        let req = request(kind: .refundOnly, amount: 1_000)
        try svc.open(req)
        clock.advance(by: 49 * 3600) // 49 hours later
        let changed = svc.runAutomation()
        XCTAssertEqual(changed, [req.id])
        XCTAssertEqual(svc.get(req.id)?.status, .autoApproved)
        XCTAssertTrue(bus.events.contains("afterSales.autoApproved:\(req.id)"))
    }

    func testAutoApprovalSkippedIfDisputed() throws {
        let (svc, clock, _, _) = setup()
        let req = request(kind: .refundOnly, amount: 1_000)
        try svc.open(req)
        try svc.dispute(id: req.id)
        clock.advance(by: 50 * 3600)
        let changed = svc.runAutomation()
        XCTAssertTrue(changed.isEmpty)
        XCTAssertNotEqual(svc.get(req.id)?.status, .autoApproved)
    }

    func testAutoApprovalNotAppliedIfAmountOverThreshold() throws {
        let (svc, clock, _, _) = setup()
        let req = request(kind: .refundOnly, amount: 5_000)
        try svc.open(req)
        clock.advance(by: 50 * 3600)
        _ = svc.runAutomation()
        XCTAssertNotEqual(svc.get(req.id)?.status, .autoApproved)
    }

    func testAutoRejectionAfter14DaysPastServiceDate() throws {
        let (svc, clock, bus, _) = setup()
        let date = Date(timeIntervalSince1970: 1_704_103_200)
        let req = request(kind: .refundOnly, amount: 1_000, created: date,
                          service: date.addingTimeInterval(-60 * 60 * 24 * 20))
        try svc.open(req)
        clock.set(date.addingTimeInterval(60 * 60)) // move clock forward a bit
        let changed = svc.runAutomation()
        XCTAssertEqual(changed, [req.id])
        XCTAssertEqual(svc.get(req.id)?.status, .autoRejected)
        XCTAssertTrue(bus.events.contains("afterSales.autoRejected:\(req.id)"))
    }

    func testAutomationSkipsTerminalStates() throws {
        let (svc, _, _, _) = setup()
        let req = request(kind: .refundOnly, amount: 1_000)
        try svc.open(req)
        try svc.close(id: req.id)
        let changed = svc.runAutomation()
        XCTAssertTrue(changed.isEmpty)
    }

    func testAllReturnsSorted() throws {
        let (svc, _, _, _) = setup()
        try svc.open(request(kind: .refundOnly))
        try svc.open(request(kind: .refundOnly))
        XCTAssertEqual(svc.all().count, 2)
    }

    func testReasonAndKindCodable() throws {
        for k in [AfterSalesKind.returnAndRefund, .refundOnly, .exchange] {
            let data = try JSONEncoder().encode(k)
            XCTAssertEqual(try JSONDecoder().decode(AfterSalesKind.self, from: data), k)
        }
        for r in [AfterSalesReason.defective, .wrongItem, .notAsDescribed, .changedMind, .late, .other] {
            let data = try JSONEncoder().encode(r)
            XCTAssertEqual(try JSONDecoder().decode(AfterSalesReason.self, from: data), r)
        }
        for s in [AfterSalesStatus.pending, .awaitingCustomer, .approved, .rejected, .closed, .autoApproved, .autoRejected] {
            let data = try JSONEncoder().encode(s)
            XCTAssertEqual(try JSONDecoder().decode(AfterSalesStatus.self, from: data), s)
        }
    }

    func testLocalNotificationBusClear() {
        let bus = LocalNotificationBus()
        bus.post("x")
        XCTAssertEqual(bus.events, ["x"])
        bus.clear()
        XCTAssertTrue(bus.events.isEmpty)
    }

    func testFakeCameraFlip() {
        let cam = FakeCamera(granted: false)
        XCTAssertFalse(cam.isGranted)
        cam.isGranted = true
        XCTAssertTrue(cam.isGranted)
    }

    func testRequestsForOrderIdFiltersCorrectly() throws {
        let (svc, _, _, _) = setup()
        let base = Date(timeIntervalSince1970: 1_704_103_200)
        // Two requests for O1 (exercises sort closure); one for O2 (exercises filter isolation).
        let reqA2 = AfterSalesRequest(id: "R-A2", orderId: "O1", kind: .refundOnly,
                                      reason: .defective, createdAt: base,
                                      serviceDate: base, amountCents: 800)
        let reqA1 = AfterSalesRequest(id: "R-A1", orderId: "O1", kind: .refundOnly,
                                      reason: .changedMind, createdAt: base,
                                      serviceDate: base, amountCents: 500)
        let reqB = AfterSalesRequest(id: "R-B", orderId: "O2", kind: .refundOnly,
                                     reason: .defective, createdAt: base,
                                     serviceDate: base, amountCents: 200)
        try svc.open(reqA2)
        try svc.open(reqA1)
        try svc.open(reqB)
        // O1 returns 2 items sorted by id: R-A1 < R-A2 (exercises sort closure)
        let o1Requests = svc.requests(for: "O1")
        XCTAssertEqual(o1Requests.count, 2)
        XCTAssertEqual(o1Requests.map { $0.id }, ["R-A1", "R-A2"])
        // O2 returns only its own request (exercises filter isolation)
        XCTAssertEqual(svc.requests(for: "O2").map { $0.id }, ["R-B"])
        // Unknown orderId returns empty (exercises empty branch)
        XCTAssertTrue(svc.requests(for: "O3").isEmpty)
    }
}
