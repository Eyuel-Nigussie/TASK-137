import XCTest
@testable import RailCommerce

/// Tests for function-level authorization on mutators that previously ran without
/// caller identity checks (audit High #5 and #6): AfterSales `respond`/`dispute`/`close`
/// and ContentPublishing `submitForReview`/`rollback`.
final class FunctionLevelAuthTests: XCTestCase {

    private let customer = User(id: "c1", displayName: "Alice", role: .customer)
    private let csr = User(id: "csr", displayName: "CSR", role: .customerService)
    private let editor = User(id: "ed", displayName: "Ed", role: .contentEditor)
    private let reviewer = User(id: "rv", displayName: "Rita", role: .contentReviewer)
    private let admin = User(id: "admin", displayName: "Admin", role: .administrator)

    // MARK: - AfterSalesService.respond

    private func afterSalesOpen() throws -> (AfterSalesService, AfterSalesRequest) {
        let svc = AfterSalesService(clock: FakeClock(),
                                    camera: FakeCamera(granted: true),
                                    notifier: LocalNotificationBus())
        let req = AfterSalesRequest(id: "R1", orderId: "O1", kind: .refundOnly,
                                    reason: .changedMind,
                                    createdAt: Date(), serviceDate: Date(),
                                    amountCents: 500)
        try svc.open(req, actingUser: customer)
        return (svc, req)
    }

    func testRespondAllowedForCSR() throws {
        let (svc, req) = try afterSalesOpen()
        XCTAssertNoThrow(try svc.respond(id: req.id, actingUser: csr))
    }

    func testRespondForbiddenForCustomer() throws {
        let (svc, req) = try afterSalesOpen()
        XCTAssertThrowsError(try svc.respond(id: req.id, actingUser: customer)) { err in
            XCTAssertEqual(err as? AuthorizationError,
                           .forbidden(required: .handleServiceTickets))
        }
    }

    func testRespondAllowedForAdmin() throws {
        let (svc, req) = try afterSalesOpen()
        XCTAssertNoThrow(try svc.respond(id: req.id, actingUser: admin))
    }

    // MARK: - AfterSalesService.dispute

    func testDisputeAllowedForCustomer() throws {
        let (svc, req) = try afterSalesOpen()
        XCTAssertNoThrow(try svc.dispute(id: req.id, actingUser: customer))
    }

    func testDisputeForbiddenForContentEditor() throws {
        let (svc, req) = try afterSalesOpen()
        XCTAssertThrowsError(try svc.dispute(id: req.id, actingUser: editor)) { err in
            XCTAssertEqual(err as? AuthorizationError,
                           .forbidden(required: .manageAfterSales))
        }
    }

    func testDisputeAllowedForCSR() throws {
        let (svc, req) = try afterSalesOpen()
        XCTAssertNoThrow(try svc.dispute(id: req.id, actingUser: csr))
    }

    // MARK: - AfterSalesService.close

    func testCloseAllowedForCSR() throws {
        let (svc, req) = try afterSalesOpen()
        XCTAssertNoThrow(try svc.close(id: req.id, actingUser: csr))
    }

    func testCloseForbiddenForCustomer() throws {
        let (svc, req) = try afterSalesOpen()
        XCTAssertThrowsError(try svc.close(id: req.id, actingUser: customer)) { err in
            XCTAssertEqual(err as? AuthorizationError,
                           .forbidden(required: .handleServiceTickets))
        }
    }

    // MARK: - ContentPublishingService.submitForReview

    private func contentDraft() throws -> ContentPublishingService {
        let svc = ContentPublishingService(clock: FakeClock(), battery: FakeBattery())
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "T",
                                tag: TaxonomyTag(), body: "v1",
                                editorId: editor.id, actingUser: editor)
        return svc
    }

    func testSubmitForReviewAllowedForEditor() throws {
        let svc = try contentDraft()
        XCTAssertNoThrow(try svc.submitForReview(id: "c1", actingUser: editor))
    }

    func testSubmitForReviewForbiddenForCustomer() throws {
        let svc = try contentDraft()
        XCTAssertThrowsError(try svc.submitForReview(id: "c1", actingUser: customer)) { err in
            XCTAssertEqual(err as? AuthorizationError,
                           .forbidden(required: .draftContent))
        }
    }

    func testSubmitForReviewForbiddenForReviewer() throws {
        let svc = try contentDraft()
        XCTAssertThrowsError(try svc.submitForReview(id: "c1", actingUser: reviewer)) { err in
            XCTAssertEqual(err as? AuthorizationError,
                           .forbidden(required: .draftContent))
        }
    }

    // MARK: - ContentPublishingService.rollback

    func testRollbackAllowedForEditor() throws {
        let svc = try contentDraft()
        _ = try svc.edit(id: "c1", body: "v2", editorId: editor.id, actingUser: editor)
        XCTAssertNoThrow(try svc.rollback(id: "c1", actingUser: editor))
    }

    func testRollbackAllowedForReviewer() throws {
        let svc = try contentDraft()
        _ = try svc.edit(id: "c1", body: "v2", editorId: editor.id, actingUser: editor)
        XCTAssertNoThrow(try svc.rollback(id: "c1", actingUser: reviewer))
    }

    func testRollbackForbiddenForCustomer() throws {
        let svc = try contentDraft()
        _ = try svc.edit(id: "c1", body: "v2", editorId: editor.id, actingUser: editor)
        XCTAssertThrowsError(try svc.rollback(id: "c1", actingUser: customer)) { err in
            XCTAssertEqual(err as? AuthorizationError,
                           .forbidden(required: .draftContent))
        }
    }

    // MARK: - Separation of duties: editor cannot approve own draft

    func testEditorCannotApproveOwnDraftWhenGrantedPublishViaAdmin() throws {
        // Configure a user with the editor's id but the reviewer's role to simulate
        // a privilege-escalation scenario. The separation-of-duties check uses the
        // user id, not the role, so same-id approvals are rejected.
        let svc = ContentPublishingService(clock: FakeClock(), battery: FakeBattery())
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "T",
                                tag: TaxonomyTag(), body: "v1",
                                editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        // Reviewer happens to share the editor's id (id == "ed"); should be rejected.
        let selfReviewer = User(id: editor.id, displayName: "Ed", role: .contentReviewer)
        XCTAssertThrowsError(try svc.approve(id: "c1", reviewer: selfReviewer)) { err in
            XCTAssertEqual(err as? ContentError, .cannotApproveOwnDraft)
        }
    }

    func testAdminCanApproveEvenIfAlsoEditor() throws {
        let svc = ContentPublishingService(clock: FakeClock(), battery: FakeBattery())
        _ = try svc.createDraft(id: "c1", kind: .travelAdvisory, title: "T",
                                tag: TaxonomyTag(), body: "v1",
                                editorId: editor.id, actingUser: editor)
        try svc.submitForReview(id: "c1", actingUser: editor)
        // Admin with id matching the editor — separation of duties does not apply to admins.
        let editorAdmin = User(id: editor.id, displayName: "Ed", role: .administrator)
        XCTAssertNoThrow(try svc.approve(id: "c1", reviewer: editorAdmin))
    }
}
