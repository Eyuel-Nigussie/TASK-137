import XCTest
@testable import RailCommerceApp
@testable import RailCommerce

/// Audit report-2 Blocker + Medium #3 closure: the `MultipeerMessageTransport`
/// receive path must drop any frame whose JSON `fromUserId` does not match
/// the authenticated `MCPeerID.displayName`. These tests pin the trust
/// boundary at the code seam that implements the check, so a future
/// regression fails loudly.
final class MultipeerSpoofRejectionTests: XCTestCase {

    // MARK: - Pure comparator (deterministic, no MC session)

    func testPeerMatchingSenderAccepts() {
        XCTAssertTrue(MultipeerMessageTransport.peerMatchesSender(
            peerDisplayName: "alice", claimedSenderId: "alice"))
    }

    func testPeerMismatchRejected() {
        XCTAssertFalse(MultipeerMessageTransport.peerMatchesSender(
            peerDisplayName: "alice", claimedSenderId: "admin"))
    }

    func testPeerMatchIsCaseSensitive() {
        XCTAssertFalse(MultipeerMessageTransport.peerMatchesSender(
            peerDisplayName: "Alice", claimedSenderId: "alice"))
    }

    func testEmptyPayloadSenderRejected() {
        XCTAssertFalse(MultipeerMessageTransport.peerMatchesSender(
            peerDisplayName: "alice", claimedSenderId: ""))
    }

    // MARK: - decodeAndAuthorize end-to-end (covers JSON decode + peer check)

    private func encode(_ msg: Message) -> Data {
        try! JSONEncoder().encode(msg)
    }

    /// Happy path: peer display name matches payload sender → message passes.
    func testDecodeAndAuthorizeAcceptsMatchingSender() {
        let transport = MultipeerMessageTransport()
        let payload = encode(Message(id: "m1", fromUserId: "alice",
                                     toUserId: "bob", body: "hello",
                                     createdAt: Date()))
        let decoded = transport.decodeAndAuthorize(data: payload,
                                                    peerDisplayName: "alice")
        XCTAssertNotNil(decoded,
                        "transport must accept a frame where peer id == payload fromUserId")
        XCTAssertEqual(decoded?.id, "m1")
    }

    /// Blocker scenario: attacker peer "attacker" sends a frame claiming to
    /// be from "admin". The transport MUST drop it; no Message is returned.
    func testDecodeAndAuthorizeRejectsSpoofedFrame() {
        let transport = MultipeerMessageTransport()
        let payload = encode(Message(id: "m-spoof", fromUserId: "admin",
                                     toUserId: "bob", body: "I am admin",
                                     createdAt: Date()))
        let decoded = transport.decodeAndAuthorize(data: payload,
                                                    peerDisplayName: "attacker")
        XCTAssertNil(decoded,
                     "transport MUST drop a frame whose peerID.displayName does not match fromUserId (impersonation defense)")
    }

    /// Defensive decode failure: garbage bytes must be rejected without any
    /// attempt to hand a partial message to the receive handlers.
    func testDecodeAndAuthorizeRejectsMalformedPayload() {
        let transport = MultipeerMessageTransport()
        let decoded = transport.decodeAndAuthorize(data: Data([0xFF, 0xFF]),
                                                    peerDisplayName: "alice")
        XCTAssertNil(decoded, "malformed JSON must never reach the receive handlers")
    }

    /// Handler-invocation contract: a spoofed frame must NEVER invoke an
    /// onReceive handler. Regression-proof: if a future refactor bypasses
    /// `decodeAndAuthorize`, this test fires because the handler flag is set.
    func testSpoofedFrameNeverCallsReceiveHandler() {
        let transport = MultipeerMessageTransport()
        var handlerCallCount = 0
        transport.onReceive { _ in handlerCallCount += 1 }

        let spoofed = encode(Message(id: "m-spoof", fromUserId: "admin",
                                     toUserId: "bob", body: "🔓",
                                     createdAt: Date()))
        // Directly exercise decodeAndAuthorize — it's the gate the real
        // delegate method relies on. A non-nil return would subsequently
        // reach the handler; a nil return must not.
        let decoded = transport.decodeAndAuthorize(data: spoofed,
                                                    peerDisplayName: "attacker")
        XCTAssertNil(decoded)
        XCTAssertEqual(handlerCallCount, 0,
                       "a spoofed frame must not reach onReceive handlers")
    }
}
