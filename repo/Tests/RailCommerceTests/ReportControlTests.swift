import XCTest
@testable import RailCommerce

/// Tests for the report/block anti-harassment controls in MessagingService.
final class ReportControlTests: XCTestCase {

    private let alice = User(id: "alice", displayName: "Alice", role: .customer)
    private let bob = User(id: "bob", displayName: "Bob", role: .customer)
    private let csr = User(id: "csr", displayName: "CSR", role: .customerService)

    func testReportMessageCreatesRecordAndBlocks() throws {
        let svc = MessagingService(clock: FakeClock())
        _ = try svc.enqueue(id: "m1", from: "alice", to: "bob", body: "hi", actingUser: alice)
        _ = svc.drainQueue()
        try svc.reportMessage("m1", reportedBy: "bob", reason: "spam", actingUser: bob)
        XCTAssertEqual(svc.reports.count, 1)
        XCTAssertEqual(svc.reports.first?.kind, .message)
        XCTAssertEqual(svc.reports.first?.targetId, "m1")
        XCTAssertTrue(svc.isBlocked(from: "alice", to: "bob"))
    }

    func testReportUserCreatesRecordAndBlocks() throws {
        let svc = MessagingService(clock: FakeClock())
        try svc.reportUser("alice", reportedBy: "bob", reason: "harassment", actingUser: bob)
        XCTAssertEqual(svc.reports.count, 1)
        XCTAssertEqual(svc.reports.first?.kind, .user)
        XCTAssertTrue(svc.isBlocked(from: "alice", to: "bob"))
    }

    func testReportedUserCannotSendToReporter() throws {
        let svc = MessagingService(clock: FakeClock())
        try svc.reportUser("alice", reportedBy: "bob", reason: "test", actingUser: bob)
        XCTAssertThrowsError(try svc.enqueue(id: "m", from: "alice", to: "bob",
                                             body: "hi", actingUser: alice)) { err in
            XCTAssertEqual(err as? MessagingError, .blockedByRecipient)
        }
    }

    func testReportRecordCodable() throws {
        let r = ReportRecord(id: "r1", kind: .message, targetId: "m1",
                             reportedBy: "bob", reason: "spam",
                             createdAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(ReportRecord.self, from: data), r)
    }

    // MARK: - Identity binding on report/block APIs

    func testCustomerCannotReportUnderAnotherIdentity() {
        let svc = MessagingService(clock: FakeClock())
        // bob is the acting user, but tries to file the report as if "alice" did.
        XCTAssertThrowsError(try svc.reportUser("attacker", reportedBy: "alice",
                                                reason: "x", actingUser: bob)) { err in
            XCTAssertEqual(err as? MessagingError, .senderIdentityMismatch)
        }
    }

    func testCustomerCannotReportMessageUnderAnotherIdentity() throws {
        let svc = MessagingService(clock: FakeClock())
        _ = try svc.enqueue(id: "m1", from: "alice", to: "bob", body: "hi", actingUser: alice)
        _ = svc.drainQueue()
        XCTAssertThrowsError(try svc.reportMessage("m1", reportedBy: "alice",
                                                   reason: "x", actingUser: bob)) { err in
            XCTAssertEqual(err as? MessagingError, .senderIdentityMismatch)
        }
    }

    func testCSRMayReportOnBehalfOfAnyUser() throws {
        let svc = MessagingService(clock: FakeClock())
        XCTAssertNoThrow(try svc.reportUser("attacker", reportedBy: "anyUser",
                                            reason: "spam", actingUser: csr))
    }

    func testCustomerCannotBlockUnderAnotherIdentity() {
        let svc = MessagingService(clock: FakeClock())
        // Bob tries to insert a block "attacker -> alice" as if alice did it.
        XCTAssertThrowsError(try svc.block(from: "attacker", to: "alice",
                                           actingUser: bob)) { err in
            XCTAssertEqual(err as? MessagingError, .senderIdentityMismatch)
        }
    }

    func testCustomerCanBlockInboundToThemselves() throws {
        let svc = MessagingService(clock: FakeClock())
        try svc.block(from: "attacker", to: "bob", actingUser: bob)
        XCTAssertTrue(svc.isBlocked(from: "attacker", to: "bob"))
    }

    func testCustomerCanUnblockInboundToThemselves() throws {
        let svc = MessagingService(clock: FakeClock())
        try svc.block(from: "attacker", to: "bob", actingUser: bob)
        try svc.unblock(from: "attacker", to: "bob", actingUser: bob)
        XCTAssertFalse(svc.isBlocked(from: "attacker", to: "bob"))
    }

    func testCSRCanBlockOnBehalfOfAnyUser() throws {
        let svc = MessagingService(clock: FakeClock())
        try svc.block(from: "attacker", to: "someVictim", actingUser: csr)
        XCTAssertTrue(svc.isBlocked(from: "attacker", to: "someVictim"))
    }
}
