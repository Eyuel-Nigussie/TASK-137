#if canImport(UIKit)
import Foundation
import MultipeerConnectivity
import RailCommerce

/// Production offline peer-to-peer transport backed by `MultipeerConnectivity`.
/// Advertises and browses on the local network / Bluetooth for nearby devices
/// running the same app. Messages are JSON-encoded and sent via MC sessions.
final class MultipeerMessageTransport: NSObject, MessageTransport,
    MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {

    private static let serviceType = "railcommerce"
    private var localPeer: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var receiveHandlers: [(Message) -> Void] = []

    override init() { super.init() }

    // MARK: - MessageTransport

    func start(asPeer peerId: String) throws {
        let peer = MCPeerID(displayName: peerId)
        localPeer = peer
        let sess = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        sess.delegate = self
        session = sess

        let adv = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil,
                                             serviceType: Self.serviceType)
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv

        let brw = MCNearbyServiceBrowser(peer: peer, serviceType: Self.serviceType)
        brw.delegate = self
        brw.startBrowsingForPeers()
        browser = brw
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        localPeer = nil
        session = nil
        advertiser = nil
        browser = nil
    }

    func onReceive(_ handler: @escaping (Message) -> Void) {
        receiveHandlers.append(handler)
    }

    @discardableResult
    func send(_ message: Message) throws -> [String] {
        guard let session = session else { throw TransportError.notStarted }
        let data = try JSONEncoder().encode(message)
        // Route only to the intended recipient peer — never fan-out to all.
        let targetPeers = session.connectedPeers.filter { $0.displayName == message.toUserId }
        guard !targetPeers.isEmpty else { return [] }
        try session.send(data, toPeers: targetPeers, with: .reliable)
        return targetPeers.map { $0.displayName }
    }

    var connectedPeers: [String] {
        (session?.connectedPeers ?? []).map { $0.displayName }
    }

    // MARK: - MCSessionDelegate

    func session(_ session: MCSession, peer peerID: MCPeerID,
                 didChange state: MCSessionState) {}

    func session(_ session: MCSession, didReceive data: Data,
                 fromPeer peerID: MCPeerID) {
        guard let msg = try? JSONDecoder().decode(Message.self, from: data) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.receiveHandlers.forEach { $0(msg) }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream,
                 withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession,
                 didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession,
                 didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?,
                 withError error: Error?) {}

    // MARK: - MCNearbyServiceAdvertiserDelegate

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    // MARK: - MCNearbyServiceBrowserDelegate

    func browser(_ browser: MCNearbyServiceBrowser,
                 foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        guard let session = session else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser,
                 lostPeer peerID: MCPeerID) {}
}
#endif
