import Foundation

/// Offline peer-to-peer transport abstraction for the messaging subsystem.
///
/// `MessagingService` delegates the actual delivery of a `Message` to an injected
/// transport. The default `InMemoryMessageTransport` keeps messages on this device
/// (the current single-device deployment). The iOS app target wires a
/// `MultipeerMessageTransport` (backed by `MultipeerConnectivity`) so two devices on
/// the same local network / Bluetooth range can exchange messages without a server.
public protocol MessageTransport: AnyObject {
    /// Deliver `message` to the recipient peer. For in-memory transports this is a
    /// synchronous hand-off; for network transports the call may be asynchronous and
    /// return before the remote peer acknowledges.
    /// - Returns: A set of peer ids the message was dispatched to. An empty array
    ///   indicates no peer was available; the caller should treat the message as
    ///   queued for later delivery.
    @discardableResult
    func send(_ message: Message) throws -> [String]

    /// Register a handler invoked when the transport receives a message from a peer.
    /// Multiple handlers compose — each one fires in registration order.
    func onReceive(_ handler: @escaping (Message) -> Void)

    /// Discover and publish the local peer's availability. Becomes a no-op on
    /// in-memory transports.
    func start(asPeer peerId: String) throws

    /// Stop advertising / browsing. Becomes a no-op on in-memory transports.
    func stop()

    /// Currently-visible peer ids (excluding the local peer).
    var connectedPeers: [String] { get }
}

public enum TransportError: Error, Equatable {
    case notStarted
    case peerUnavailable(String)
    case encodingFailed
}

/// Default transport used by tests, Linux CI, and single-device deployments.
///
/// A shared "bus" is keyed by peer id. When `A` calls `send(msg)` the transport
/// looks up the peer the message is addressed to on the shared bus and invokes
/// their receive handlers. Useful for testing multi-peer flows without a network.
public final class InMemoryMessageTransport: MessageTransport {
    private static var bus: [String: [(Message) -> Void]] = [:]
    private static let queue = DispatchQueue(label: "railcommerce.transport.inmem")

    private var peerId: String?
    private var receiveHandlers: [(Message) -> Void] = []

    public init() {}

    public func start(asPeer peerId: String) throws {
        self.peerId = peerId
        Self.queue.sync {
            Self.bus[peerId, default: []].append(contentsOf: receiveHandlers)
        }
    }

    public func stop() {
        guard let peerId = peerId else { return }
        _ = Self.queue.sync {
            Self.bus.removeValue(forKey: peerId)
        }
        self.peerId = nil
    }

    public func onReceive(_ handler: @escaping (Message) -> Void) {
        receiveHandlers.append(handler)
        guard let peerId = peerId else { return }
        Self.queue.sync {
            Self.bus[peerId, default: []].append(handler)
        }
    }

    @discardableResult
    public func send(_ message: Message) throws -> [String] {
        guard peerId != nil else { throw TransportError.notStarted }
        let handlers = Self.queue.sync { Self.bus[message.toUserId] ?? [] }
        guard !handlers.isEmpty else { return [] }
        for h in handlers { h(message) }
        return [message.toUserId]
    }

    public var connectedPeers: [String] {
        Self.queue.sync {
            Self.bus.keys.filter { $0 != peerId }.sorted()
        }
    }

    /// Test helper: wipe the shared bus between tests.
    public static func resetBusForTesting() {
        queue.sync { bus.removeAll() }
    }
}
