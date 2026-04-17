import XCTest
@testable import RailCommerce

/// v6-audit closure tests: inbound P2P messages must pass through the same
/// safety pipeline as outbound `enqueue` — block list, sensitive-data
/// scanner, harassment filter, attachment size/type guards, and contact
/// masking on body. Anything that fails a guard is DROPPED (never delivered,
/// never persisted) so a remote peer cannot bypass moderation by crafting
/// a payload directly on the transport.
final class InboundMessagingValidationTests: XCTestCase {

    /// Helper: builds a messaging service backed by a controllable transport
    /// so tests can simulate inbound payloads without real peers.
    private func setup() -> (MessagingService, TestTransport) {
        let transport = TestTransport()
        let svc = MessagingService(clock: FakeClock(), transport: transport)
        return (svc, transport)
    }

    // MARK: - Block list enforcement on inbound

    func testInboundFromBlockedSenderIsDropped() throws {
        let (svc, transport) = setup()
        let csr = User(id: "csr", displayName: "CSR", role: .customerService)
        try svc.block(from: "attacker", to: "me", actingUser: csr)

        transport.simulateInbound(Message(
            id: "m1", fromUserId: "attacker", toUserId: "me", body: "hi",
            createdAt: Date()))

        XCTAssertTrue(svc.deliveredMessages.isEmpty,
                      "Blocked sender's inbound message must not be delivered")
    }

    // MARK: - Sensitive-data rejection on inbound

    func testInboundSSNIsDropped() {
        let (svc, transport) = setup()
        transport.simulateInbound(Message(
            id: "m1", fromUserId: "peer", toUserId: "me",
            body: "my ssn is 123-45-6789", createdAt: Date()))
        XCTAssertTrue(svc.deliveredMessages.isEmpty)
    }

    func testInboundPaymentCardIsDropped() {
        let (svc, transport) = setup()
        transport.simulateInbound(Message(
            id: "m1", fromUserId: "peer", toUserId: "me",
            body: "card 4111 1111 1111 1111", createdAt: Date()))
        XCTAssertTrue(svc.deliveredMessages.isEmpty)
    }

    // MARK: - Harassment filter on inbound — auto-block after 3 strikes

    func testInboundHarassmentCountsStrikesAndAutoBlocks() {
        let (svc, transport) = setup()
        for i in 0..<3 {
            transport.simulateInbound(Message(
                id: "m\(i)", fromUserId: "badpeer", toUserId: "me",
                body: "you idiot", createdAt: Date()))
        }
        XCTAssertEqual(svc.strikes(for: "badpeer"), 3)
        XCTAssertTrue(svc.isBlocked(from: "badpeer", to: "me"),
                      "Three inbound harassment hits must auto-block the sender")
        XCTAssertTrue(svc.deliveredMessages.isEmpty)
    }

    // MARK: - Attachment guards on inbound

    func testInboundOversizedAttachmentIsDropped() {
        let (svc, transport) = setup()
        let huge = MessageAttachment(id: "big", kind: .jpeg,
                                      sizeBytes: MessagingService.maxAttachmentBytes + 1)
        transport.simulateInbound(Message(
            id: "m1", fromUserId: "peer", toUserId: "me", body: "see attached",
            attachments: [huge], createdAt: Date()))
        XCTAssertTrue(svc.deliveredMessages.isEmpty)
    }

    // MARK: - Contact masking on inbound

    func testInboundBodyIsMaskedBeforeDelivery() {
        let (svc, transport) = setup()
        transport.simulateInbound(Message(
            id: "m1", fromUserId: "peer", toUserId: "me",
            body: "call 555-123-4567 or email me@example.com",
            createdAt: Date()))
        XCTAssertEqual(svc.deliveredMessages.count, 1)
        let delivered = svc.deliveredMessages[0]
        XCTAssertTrue(delivered.body.contains("***-***-4567"),
                      "Inbound phone numbers must be masked")
        XCTAssertTrue(delivered.body.contains("****@****"),
                      "Inbound emails must be masked")
    }

    // MARK: - Happy path: clean inbound is delivered

    func testInboundCleanMessageIsDelivered() {
        let (svc, transport) = setup()
        transport.simulateInbound(Message(
            id: "m1", fromUserId: "peer", toUserId: "me",
            body: "safe and friendly", createdAt: Date()))
        XCTAssertEqual(svc.deliveredMessages.count, 1)
        XCTAssertEqual(svc.deliveredMessages[0].id, "m1")
    }

    // MARK: - Thread-scoped inbound also passes through pipeline

    func testInboundThreadedMessagePreservesThreadIdAndMasks() {
        let (svc, transport) = setup()
        transport.simulateInbound(Message(
            id: "m1", fromUserId: "peer", toUserId: "me",
            body: "ping me at 555-111-2222", createdAt: Date(),
            threadId: "case-42"))
        XCTAssertEqual(svc.deliveredMessages.count, 1)
        XCTAssertEqual(svc.deliveredMessages[0].threadId, "case-42")
        XCTAssertTrue(svc.deliveredMessages[0].body.contains("***-***-2222"))
    }
}

// MARK: - Test transport double

/// Minimal transport that exposes a `simulateInbound` hook to drive the
/// `MessagingService` receive handler directly.
private final class TestTransport: MessageTransport {
    private var handlers: [(Message) -> Void] = []

    func send(_ message: Message) throws -> [String] { [] }
    func onReceive(_ handler: @escaping (Message) -> Void) { handlers.append(handler) }
    func start(asPeer peerId: String) throws {}
    func stop() {}
    var connectedPeers: [String] { [] }

    func simulateInbound(_ msg: Message) { handlers.forEach { $0(msg) } }
}
