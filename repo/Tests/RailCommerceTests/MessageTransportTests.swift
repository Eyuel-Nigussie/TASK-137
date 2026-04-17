import XCTest
@testable import RailCommerce

/// Tests for `InMemoryMessageTransport` — the offline peer-to-peer transport used
/// by MessagingService for local-device message delivery.
final class MessageTransportTests: XCTestCase {

    override func setUp() {
        super.setUp()
        InMemoryMessageTransport.resetBusForTesting()
    }

    override func tearDown() {
        InMemoryMessageTransport.resetBusForTesting()
        super.tearDown()
    }

    private func makeMessage(id: String = "m1", from: String = "alice",
                             to: String = "bob") -> Message {
        Message(id: id, fromUserId: from, toUserId: to, body: "hi",
                attachments: [], createdAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Lifecycle

    func testSendBeforeStartThrows() {
        let t = InMemoryMessageTransport()
        XCTAssertThrowsError(try t.send(makeMessage())) { err in
            XCTAssertEqual(err as? TransportError, .notStarted)
        }
    }

    func testStartAndStopToggleAvailability() throws {
        let t = InMemoryMessageTransport()
        try t.start(asPeer: "alice")
        XCTAssertNoThrow(try t.send(makeMessage(to: "alice"))) // self-loop, works
        t.stop()
        XCTAssertThrowsError(try t.send(makeMessage())) { err in
            XCTAssertEqual(err as? TransportError, .notStarted)
        }
    }

    // MARK: - Delivery

    func testSendReachesRegisteredPeer() throws {
        let sender = InMemoryMessageTransport()
        let receiver = InMemoryMessageTransport()
        var received: [Message] = []
        receiver.onReceive { received.append($0) }
        try receiver.start(asPeer: "bob")
        try sender.start(asPeer: "alice")

        let msg = makeMessage(from: "alice", to: "bob")
        let peers = try sender.send(msg)
        XCTAssertEqual(peers, ["bob"])
        XCTAssertEqual(received.map { $0.id }, ["m1"])
    }

    func testSendWithNoReachablePeerReturnsEmpty() throws {
        let sender = InMemoryMessageTransport()
        try sender.start(asPeer: "alice")
        let peers = try sender.send(makeMessage(from: "alice", to: "ghost"))
        XCTAssertTrue(peers.isEmpty)
    }

    func testConnectedPeersExcludesSelf() throws {
        let a = InMemoryMessageTransport()
        let b = InMemoryMessageTransport()
        try a.start(asPeer: "a")
        try b.start(asPeer: "b")
        // Each transport sees the other but not itself.
        XCTAssertTrue(a.connectedPeers.contains("b"))
        XCTAssertFalse(a.connectedPeers.contains("a"))
    }

    func testMultipleHandlersAllFireInOrder() throws {
        let r = InMemoryMessageTransport()
        var order: [String] = []
        r.onReceive { _ in order.append("h1") }
        r.onReceive { _ in order.append("h2") }
        try r.start(asPeer: "r")

        let s = InMemoryMessageTransport()
        try s.start(asPeer: "s")
        _ = try s.send(makeMessage(from: "s", to: "r"))

        XCTAssertEqual(order, ["h1", "h2"])
    }

    // MARK: - MessagingService ↔ transport integration

    func testMessagingServiceDeliversViaTransport() throws {
        let transport = InMemoryMessageTransport()
        try transport.start(asPeer: "receiver")
        var received: [Message] = []
        transport.onReceive { received.append($0) }

        let sender = InMemoryMessageTransport()
        try sender.start(asPeer: "sender")
        let svc = MessagingService(clock: FakeClock(), transport: sender)
        let alice = User(id: "sender", displayName: "Alice", role: .customer)

        _ = try svc.enqueue(id: "m1", from: "sender", to: "receiver",
                            body: "hi", actingUser: alice)
        _ = svc.drainQueue()
        XCTAssertEqual(received.map { $0.id }, ["m1"])
    }

    func testTransportErrorEquality() {
        XCTAssertEqual(TransportError.notStarted, TransportError.notStarted)
        XCTAssertNotEqual(TransportError.notStarted, TransportError.peerUnavailable("x"))
        XCTAssertEqual(TransportError.peerUnavailable("x"), TransportError.peerUnavailable("x"))
    }
}
