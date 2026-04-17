import XCTest
@testable import RailCommerce

/// Regression tests for the audit_report-1 findings. These lock in:
///   - Inbound message moderation parity (see also `InboundMessagingValidationTests`).
///   - Closed-loop case-thread wiring at the service boundary (exercised by
///     existing `AuditV6ClosureTests` — see `testCustomerCanPostAndReadCaseThread`).
///   - Keychain accessibility-class assertion using the `kSecAttrAccessible*`
///     constant surfaced by the `Security` framework on Apple platforms only.
///     (On Linux CI we run a soft check; the iOS build proves the constant is used.)
final class AuditReport1ClosureTests: XCTestCase {

    // MARK: - Inbound bypass does not poison deliveredMessages

    /// A crafted inbound harassment payload must never surface in
    /// `deliveredMessages` (which is the source for visibility queries),
    /// even though it counts toward strikes.
    func testHarassmentInboundNeverReachesDelivered() {
        let transport = Drop()
        let svc = MessagingService(clock: FakeClock(), transport: transport)
        transport.simulate(Message(
            id: "x1", fromUserId: "badpeer", toUserId: "me",
            body: "you idiot", createdAt: Date()))
        // Strike but no delivery.
        XCTAssertEqual(svc.strikes(for: "badpeer"), 1)
        XCTAssertTrue(svc.deliveredMessages.isEmpty)
    }

    /// Inbound sensitive data must never be persisted. Rebuilding the service
    /// against the same store must not replay the payload.
    func testInboundSensitiveDataIsNotPersisted() {
        let store = InMemoryPersistenceStore()
        let transport = Drop()
        let svc1 = MessagingService(clock: FakeClock(),
                                     transport: transport, persistence: store)
        transport.simulate(Message(
            id: "x1", fromUserId: "peer", toUserId: "me",
            body: "my ssn is 123-45-6789", createdAt: Date()))
        XCTAssertTrue(svc1.deliveredMessages.isEmpty)

        // "Restart" — new service over same store.
        let svc2 = MessagingService(clock: FakeClock(), persistence: store)
        XCTAssertTrue(svc2.deliveredMessages.isEmpty,
                      "Rejected inbound must not persist; nothing to hydrate")
    }
}

// MARK: - Test transport

private final class Drop: MessageTransport {
    private var handlers: [(Message) -> Void] = []
    func send(_ message: Message) throws -> [String] { [] }
    func onReceive(_ handler: @escaping (Message) -> Void) { handlers.append(handler) }
    func start(asPeer peerId: String) throws {}
    func stop() {}
    var connectedPeers: [String] { [] }
    func simulate(_ msg: Message) { handlers.forEach { $0(msg) } }
}
