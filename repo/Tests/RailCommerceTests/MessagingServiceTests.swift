import XCTest
@testable import RailCommerce

final class MessagingServiceTests: XCTestCase {
    // CSR is used so the identity-binding relaxation (`.sendStaffMessage`) applies.
    // Customer-as-sender tests that exercise identity binding use `aliceUser` (id matches `from`).
    private let testUser = User(id: "u1", displayName: "CSR", role: .customerService)
    private let aliceUser = User(id: "alice", displayName: "Alice", role: .customer)

    private func setup() -> (MessagingService, FakeClock) {
        let clock = FakeClock()
        return (MessagingService(clock: clock), clock)
    }

    func testEnqueueQueuesAndDrains() throws {
        let (svc, clock) = setup()
        _ = try svc.enqueue(id: "m1", from: "a", to: "b", body: "hello", actingUser: testUser)
        XCTAssertEqual(svc.queue.count, 1)
        clock.advance(by: 10)
        let delivered = svc.drainQueue()
        XCTAssertEqual(delivered.first?.deliveredAt, clock.now())
        XCTAssertTrue(svc.queue.isEmpty)
        XCTAssertEqual(svc.deliveredMessages.count, 1)
    }

    func testBlockingPreventsDelivery() throws {
        let (svc, _) = setup()
        // testUser is the CSR, whose `.sendStaffMessage` permission allows
        // blocking on behalf of any recipient.
        try svc.block(from: "a", to: "b", actingUser: testUser)
        XCTAssertThrowsError(try svc.enqueue(id: "m1", from: "a", to: "b", body: "hi", actingUser: testUser)) { err in
            XCTAssertEqual(err as? MessagingError, .blockedByRecipient)
        }
        try svc.unblock(from: "a", to: "b", actingUser: testUser)
        _ = try svc.enqueue(id: "m2", from: "a", to: "b", body: "hi again", actingUser: testUser)
        XCTAssertEqual(svc.queue.count, 1)
    }

    func testSSNBlocked() {
        let (svc, _) = setup()
        XCTAssertThrowsError(try svc.enqueue(id: "x", from: "a", to: "b",
                                             body: "my ssn is 123-45-6789",
                                             actingUser: testUser)) { err in
            if case .sensitiveDataBlocked(let kind) = err as? MessagingError {
                XCTAssertEqual(kind, .ssn)
            } else { XCTFail("wrong error") }
        }
    }

    func testPaymentCardBlocked() {
        let (svc, _) = setup()
        XCTAssertThrowsError(try svc.enqueue(id: "x", from: "a", to: "b",
                                             body: "card 4111 1111 1111 1111",
                                             actingUser: testUser)) { err in
            if case .sensitiveDataBlocked(let kind) = err as? MessagingError {
                XCTAssertEqual(kind, .paymentCard)
            } else { XCTFail("wrong error") }
        }
    }

    func testHarassmentFiltersAndStrikes() {
        let (svc, _) = setup()
        for _ in 0..<3 {
            XCTAssertThrowsError(try svc.enqueue(id: UUID().uuidString, from: "a", to: "b",
                                                 body: "you idiot", actingUser: testUser))
        }
        XCTAssertEqual(svc.strikes(for: "a"), 3)
        XCTAssertTrue(svc.isBlocked(from: "a", to: "b"))
    }

    func testAttachmentTooLarge() {
        let (svc, _) = setup()
        let att = MessageAttachment(id: "x", kind: .jpeg, sizeBytes: 20 * 1024 * 1024)
        XCTAssertThrowsError(try svc.enqueue(id: "m", from: "a", to: "b",
                                             body: "hi", attachments: [att],
                                             actingUser: testUser)) { err in
            XCTAssertEqual(err as? MessagingError, .attachmentTooLarge)
        }
    }

    func testAttachmentAllowedTypes() throws {
        let (svc, _) = setup()
        for k in [AttachmentKind.jpeg, .png, .pdf] {
            _ = try svc.enqueue(id: UUID().uuidString, from: "a", to: "b", body: "ok",
                                attachments: [MessageAttachment(id: "id", kind: k, sizeBytes: 1_000)],
                                actingUser: testUser)
        }
    }

    func testContactMaskingApplied() throws {
        let (svc, _) = setup()
        let m = try svc.enqueue(id: "m", from: "a", to: "b",
                                body: "email me at alice@example.com or call 555-123-4567",
                                actingUser: testUser)
        XCTAssertTrue(m.body.contains("****@****"))
        // Last 4 digits of 555-123-4567 are preserved: ***-***-4567
        XCTAssertTrue(m.body.contains("***-***-4567"))
    }

    func testSensitiveScannerReturnsNilForClean() {
        XCTAssertNil(SensitiveDataScanner.scan("hello world"))
    }

    func testHarassmentFilterClean() {
        XCTAssertFalse(HarassmentFilter.isHarassing("lovely day"))
    }

    func testMessageRoundTripCodable() throws {
        let m = Message(id: "m", fromUserId: "a", toUserId: "b", body: "hi",
                        attachments: [MessageAttachment(id: "x", kind: .pdf, sizeBytes: 1)],
                        createdAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(m)
        XCTAssertEqual(try JSONDecoder().decode(Message.self, from: data), m)
    }

    func testAttachmentKindRoundTrip() throws {
        for k in [AttachmentKind.jpeg, .png, .pdf] {
            let data = try JSONEncoder().encode(k)
            XCTAssertEqual(try JSONDecoder().decode(AttachmentKind.self, from: data), k)
        }
    }

    func testContactMaskerPassesThroughNonMatching() {
        XCTAssertEqual(ContactMasker.mask("plain text"), "plain text")
    }

    func testStrikesAndIsBlockedInitialZero() {
        let svc = MessagingService(clock: FakeClock())
        XCTAssertEqual(svc.strikes(for: "nobody"), 0)
        XCTAssertFalse(svc.isBlocked(from: "x", to: "y"))
    }

    func testRegexReplacingWithMalformedPatternStaysIntact() {
        // Exercises the fallback path in the replacing helper.
        let original = "hello"
        XCTAssertEqual(original.replacing(pattern: "(", with: "_"), original)
    }

    func testAttachmentNonListedTypeStillRoundtripsEnum() {
        // This just exercises the switch all-arms compile-time exhaustiveness.
        let a = MessageAttachment(id: "id", kind: .png, sizeBytes: 0)
        XCTAssertEqual(a.kind, .png)
    }

    // MARK: - User-scoped message queries

    func testMessagesFromUserIsolated() throws {
        let (svc, _) = setup()
        _ = try svc.enqueue(id: "m1", from: "alice", to: "bob", body: "hi bob", actingUser: testUser)
        _ = try svc.enqueue(id: "m2", from: "bob", to: "alice", body: "hey alice", actingUser: testUser)
        _ = svc.drainQueue()
        XCTAssertEqual(svc.messages(from: "alice").map { $0.id }, ["m1"])
        XCTAssertEqual(svc.messages(from: "bob").map { $0.id }, ["m2"])
        XCTAssertTrue(svc.messages(from: "carol").isEmpty)
    }

    func testMessagesToUserIsolated() throws {
        let (svc, _) = setup()
        _ = try svc.enqueue(id: "m1", from: "alice", to: "bob", body: "hi", actingUser: testUser)
        _ = try svc.enqueue(id: "m2", from: "carol", to: "bob", body: "hello", actingUser: testUser)
        _ = svc.drainQueue()
        XCTAssertEqual(svc.messages(to: "bob").count, 2)
        XCTAssertTrue(svc.messages(to: "alice").isEmpty)
    }
}
