import Foundation
import RxSwift

public enum AttachmentKind: String, Codable, Sendable {
    case jpeg
    case png
    case pdf
}

public struct MessageAttachment: Codable, Equatable, Sendable {
    public let id: String
    public let kind: AttachmentKind
    public let sizeBytes: Int

    public init(id: String, kind: AttachmentKind, sizeBytes: Int) {
        self.id = id; self.kind = kind; self.sizeBytes = sizeBytes
    }
}

public struct Message: Codable, Equatable, Sendable {
    public let id: String
    public let fromUserId: String
    public let toUserId: String
    public let body: String
    public let attachments: [MessageAttachment]
    public let createdAt: Date
    public var deliveredAt: Date?
    /// Optional thread / case identifier. When set, this message is part of a
    /// conversation scoped to an external case (e.g. an after-sales request id).
    /// Closed-loop CS messaging uses this to group a customer+CSR conversation
    /// around a single ticket and to enforce per-thread visibility rules.
    public let threadId: String?

    public init(id: String, fromUserId: String, toUserId: String, body: String,
                attachments: [MessageAttachment] = [], createdAt: Date,
                deliveredAt: Date? = nil, threadId: String? = nil) {
        self.id = id; self.fromUserId = fromUserId; self.toUserId = toUserId
        self.body = body; self.attachments = attachments
        self.createdAt = createdAt; self.deliveredAt = deliveredAt
        self.threadId = threadId
    }
}

/// A persisted abuse-report record, created by `reportMessage` or `reportUser`.
public struct ReportRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case message, user }
    public let id: String
    public let kind: Kind
    public let targetId: String
    public let reportedBy: String
    public let reason: String
    public let createdAt: Date
}

public enum MessagingError: Error, Equatable {
    case sensitiveDataBlocked(kind: SensitiveKind)
    case attachmentTooLarge
    case attachmentTypeNotAllowed
    case harassmentBlocked
    case blockedByRecipient
    /// Thrown when the supplied `from` id does not match the authenticated caller's id.
    /// Prevents authenticated users from forging the sender field.
    case senderIdentityMismatch
    case persistenceFailed
    case transportFailed
}

public enum SensitiveKind: String, Equatable, Sendable {
    case ssn
    case paymentCard
}

public enum ContactMasker {
    /// Masks email addresses to `****@****` and US phone numbers to `***-***-XXXX`
    /// where XXXX is the actual last four digits (preserved for service context).
    public static func mask(_ body: String) -> String {
        var out = body
        // Email masking
        let emailPattern = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
        out = out.replacing(pattern: emailPattern, with: "****@****")
        // Phone masking — preserve the last 4 digits in capture group 1.
        let phonePattern = "\\(?\\d{3}\\)?[-. ]?\\d{3}[-. ]?(\\d{4})"
        out = out.replacing(pattern: phonePattern, with: "***-***-$1")
        return out
    }
}

public enum SensitiveDataScanner {
    public static func scan(_ body: String) -> SensitiveKind? {
        if ssnRegex.firstMatch(in: body) != nil { return .ssn }
        if cardRegex.firstMatch(in: body) != nil { return .paymentCard }
        return nil
    }

    private static let ssnRegex = try! NSRegularExpression(pattern: "\\b\\d{3}-\\d{2}-\\d{4}\\b")
    // 13-19 digit sequences with optional spaces/hyphens, cover Visa/MC/Amex/etc.
    private static let cardRegex = try! NSRegularExpression(
        pattern: "\\b(?:\\d[ -]*?){13,19}\\b"
    )
}

public enum HarassmentFilter {
    public static let bannedWords: Set<String> = ["idiot", "stupid", "loser", "hate"]

    public static func isHarassing(_ body: String) -> Bool {
        let lower = body.lowercased()
        return bannedWords.contains { lower.contains($0) }
    }
}

public final class MessagingService {
    public static let maxAttachmentBytes = 10 * 1024 * 1024
    public static let persistencePrefix = "messaging.msg."

    private let clock: any Clock
    private let transport: MessageTransport?
    private let persistence: PersistenceStore?
    private let logger: Logger
    private var queued: [Message] = []
    private var delivered: [Message] = []
    private var blocks: Set<String> = [] // "from|to" pairs
    private var harassmentStrikes: [String: Int] = [:]

    private let _events = PublishSubject<MessagingEvent>()
    /// Observable stream of messaging lifecycle events.
    public var events: Observable<MessagingEvent> { _events.asObservable() }

    public init(clock: any Clock,
                transport: MessageTransport? = nil,
                persistence: PersistenceStore? = nil,
                logger: Logger = SilentLogger()) {
        self.clock = clock
        self.transport = transport
        self.persistence = persistence
        self.logger = logger
        hydrate()
        // Accept inbound messages from the transport layer.
        transport?.onReceive { [weak self] msg in
            self?.acceptInbound(msg)
        }
    }

    public var queue: [Message] { queued }
    public var deliveredMessages: [Message] { delivered }

    /// Attachment ids currently referenced by queued or delivered messages.
    /// Used by `AttachmentService.runRetentionSweep` to avoid purging attachments
    /// that are still referenced by a live message.
    public func referencedAttachmentIds() -> Set<String> {
        var ids: Set<String> = []
        for m in queued { for a in m.attachments { ids.insert(a.id) } }
        for m in delivered { for a in m.attachments { ids.insert(a.id) } }
        return ids
    }

    /// Adds a block on sender→recipient. Requires `actingUser` identity binding:
    /// a caller may only block outbound to themselves (i.e. block someone from
    /// sending to me), unless they hold CSR `.sendStaffMessage` or admin
    /// `.configureSystem`, in which case they may block on behalf of others.
    public func block(from: String, to: String, actingUser: User) throws {
        try enforceBlockIdentity(recipient: to, actingUser: actingUser)
        blocks.insert("\(from)|\(to)")
    }

    /// Removes a previously-set block. Same identity-binding rules as `block`.
    public func unblock(from: String, to: String, actingUser: User) throws {
        try enforceBlockIdentity(recipient: to, actingUser: actingUser)
        blocks.remove("\(from)|\(to)")
    }

    private func enforceBlockIdentity(recipient: String, actingUser: User) throws {
        if actingUser.id == recipient { return }
        if RolePolicy.can(actingUser.role, .sendStaffMessage) { return }
        if RolePolicy.can(actingUser.role, .configureSystem) { return }
        logger.warn(.messaging, "block identityMismatch actor=\(actingUser.id) recipient=\(recipient)")
        throw MessagingError.senderIdentityMismatch
    }

    /// Returns all delivered messages sent by `userId`.
    public func messages(from userId: String) -> [Message] {
        delivered.filter { $0.fromUserId == userId }
    }

    /// Returns all delivered messages addressed to `userId`.
    public func messages(to userId: String) -> [Message] {
        delivered.filter { $0.toUserId == userId }
    }

    /// Returns the delivered messages visible to `userId` — both sent and received.
    /// Object-level isolation: callers must be the user themselves; privileged roles
    /// (admin, CSR) can audit by passing the actingUser.
    public func messagesVisibleTo(_ userId: String, actingUser: User) throws -> [Message] {
        if actingUser.id == userId
           || RolePolicy.can(actingUser.role, .handleServiceTickets)
           || RolePolicy.can(actingUser.role, .configureSystem) {
            return delivered.filter { $0.fromUserId == userId || $0.toUserId == userId }
        }
        throw AuthorizationError.forbidden(required: .handleServiceTickets)
    }

    /// Enqueues a message after applying safety checks and contact masking.
    /// Identity binding: `from` must match `actingUser.id` unless the caller holds
    /// `.sendStaffMessage` (CSR) or `.configureSystem` (administrator).
    /// - Parameter actingUser: The caller's role is validated against `.browseContent`
    ///   (held by every valid role); this ensures callers are authenticated system users.
    @discardableResult
    public func enqueue(id: String, from: String, to: String,
                        body: String, attachments: [MessageAttachment] = [],
                        actingUser: User, threadId: String? = nil) throws -> Message {
        try RolePolicy.enforce(user: actingUser, .browseContent)
        // Identity binding: prevent the authenticated caller from forging a sender id.
        if actingUser.id != from
           && !RolePolicy.can(actingUser.role, .sendStaffMessage)
           && !RolePolicy.can(actingUser.role, .configureSystem) {
            logger.warn(.messaging, "enqueue identityMismatch actor=\(actingUser.id) from=\(from)")
            throw MessagingError.senderIdentityMismatch
        }
        if blocks.contains("\(from)|\(to)") {
            throw MessagingError.blockedByRecipient
        }
        if let kind = SensitiveDataScanner.scan(body) {
            logger.warn(.messaging, "enqueue sensitiveBlocked kind=\(kind.rawValue) id=\(id)")
            throw MessagingError.sensitiveDataBlocked(kind: kind)
        }
        if HarassmentFilter.isHarassing(body) {
            let next = (harassmentStrikes[from] ?? 0) + 1
            harassmentStrikes[from] = next
            if next >= 3 {
                blocks.insert("\(from)|\(to)")
            }
            logger.warn(.messaging, "enqueue harassmentBlocked from=\(from) strikes=\(next)")
            throw MessagingError.harassmentBlocked
        }
        for a in attachments {
            if a.sizeBytes > Self.maxAttachmentBytes { throw MessagingError.attachmentTooLarge }
            switch a.kind {
            case .jpeg, .png, .pdf: break
            }
        }
        let masked = ContactMasker.mask(body)
        let msg = Message(id: id, fromUserId: from, toUserId: to, body: masked,
                          attachments: attachments, createdAt: clock.now(),
                          threadId: threadId)
        queued.append(msg)
        try persist(msg)
        _events.onNext(.messageEnqueued(id))
        let threadTag = threadId.map { " thread=\($0)" } ?? ""
        logger.info(.messaging, "enqueue id=\(id) from=\(from) to=\(to)\(threadTag) body=\(masked)")
        return msg
    }

    /// Returns messages belonging to a conversation thread (e.g. the CS thread
    /// attached to an after-sales request). Object-level visibility applies:
    /// the caller must be sender OR recipient of at least the thread scope, OR
    /// hold `.handleServiceTickets` / `.configureSystem` to audit any thread.
    public func messages(inThread threadId: String, actingUser: User) throws -> [Message] {
        let all = (delivered + queued).filter { $0.threadId == threadId }
        if RolePolicy.can(actingUser.role, .handleServiceTickets)
           || RolePolicy.can(actingUser.role, .configureSystem) {
            return all.sorted { $0.createdAt < $1.createdAt }
        }
        // Non-privileged: only messages where the actor is a participant.
        let mine = all.filter {
            $0.fromUserId == actingUser.id || $0.toUserId == actingUser.id
        }
        guard !mine.isEmpty || all.isEmpty else {
            // The thread exists but the caller is not a participant — reject
            // rather than silently hand back an empty list.
            logger.warn(.messaging, "messages(inThread:) forbidden actor=\(actingUser.id) thread=\(threadId)")
            throw AuthorizationError.forbidden(required: .handleServiceTickets)
        }
        return mine.sorted { $0.createdAt < $1.createdAt }
    }

    /// Attempts to deliver queued messages via the transport layer. Messages are
    /// only moved to the delivered set when the transport confirms at least one
    /// recipient received them. Messages that cannot be delivered remain queued
    /// for the next drain cycle — this upholds the offline-queue contract.
    @discardableResult
    public func drainQueue() -> [Message] {
        let now = clock.now()
        var deliveredNow: [Message] = []
        var stillQueued: [Message] = []

        for var msg in queued {
            var dispatched = false
            if let transport = transport {
                do {
                    let peers = try transport.send(msg)
                    dispatched = !peers.isEmpty
                } catch {
                    logger.error(.transport, "send failed id=\(msg.id) err=\(error)")
                }
            } else {
                // No transport wired — treat as local-only delivery.
                dispatched = true
            }

            if dispatched {
                msg.deliveredAt = now
                deliveredNow.append(msg)
                // Delivery already succeeded through the transport; the
                // persistence record is a post-hoc audit entry and cannot be
                // un-delivered. Log the failure so the missing audit row is
                // forensically traceable rather than silently swallowed.
                do {
                    try persist(msg)
                } catch {
                    logger.error(.messaging,
                                 "drainQueue persist failed id=\(msg.id) err=\(error) (message delivered; audit row lost)")
                }
            } else {
                stillQueued.append(msg)
                logger.info(.messaging, "drainQueue requeued id=\(msg.id) (no peer)")
            }
        }

        delivered.append(contentsOf: deliveredNow)
        queued = stillQueued
        _events.onNext(.queueDrained(deliveredNow.count))
        logger.info(.messaging, "drainQueue delivered=\(deliveredNow.count) requeued=\(stillQueued.count)")
        return deliveredNow
    }

    public func strikes(for user: String) -> Int { harassmentStrikes[user] ?? 0 }
    public func isBlocked(from: String, to: String) -> Bool { blocks.contains("\(from)|\(to)") }

    // MARK: - Report controls

    private(set) public var reports: [ReportRecord] = []

    /// Report a specific message for abuse. Creates a persisted report record and
    /// auto-blocks the sender→recipient pair.
    ///
    /// Authorization: `actingUser.id` must equal `reportedBy` (a user may only
    /// file reports under their own identity), unless the caller holds CSR
    /// `.sendStaffMessage` or admin `.configureSystem` — privileged staff may
    /// file on behalf of a reporting user.
    public func reportMessage(_ messageId: String, reportedBy: String, reason: String,
                              actingUser: User) throws {
        try enforceReportIdentity(reportedBy: reportedBy, actingUser: actingUser)
        let record = ReportRecord(id: UUID().uuidString, kind: .message,
                                  targetId: messageId, reportedBy: reportedBy,
                                  reason: reason, createdAt: clock.now())
        reports.append(record)
        if let msg = (delivered + queued).first(where: { $0.id == messageId }) {
            blocks.insert("\(msg.fromUserId)|\(reportedBy)")
        }
        logger.info(.messaging, "reportMessage id=\(messageId) by=\(reportedBy) actor=\(actingUser.id)")
    }

    /// Report a user for general abuse. Same identity binding as `reportMessage`.
    public func reportUser(_ targetUserId: String, reportedBy: String, reason: String,
                           actingUser: User) throws {
        try enforceReportIdentity(reportedBy: reportedBy, actingUser: actingUser)
        let record = ReportRecord(id: UUID().uuidString, kind: .user,
                                  targetId: targetUserId, reportedBy: reportedBy,
                                  reason: reason, createdAt: clock.now())
        reports.append(record)
        blocks.insert("\(targetUserId)|\(reportedBy)")
        logger.info(.messaging, "reportUser target=\(targetUserId) by=\(reportedBy) actor=\(actingUser.id)")
    }

    private func enforceReportIdentity(reportedBy: String, actingUser: User) throws {
        if actingUser.id == reportedBy { return }
        if RolePolicy.can(actingUser.role, .sendStaffMessage) { return }
        if RolePolicy.can(actingUser.role, .configureSystem) { return }
        logger.warn(.messaging, "report identityMismatch actor=\(actingUser.id) reportedBy=\(reportedBy)")
        throw MessagingError.senderIdentityMismatch
    }

    // MARK: - Transport integration

    /// Validates an inbound transport message against **the same safety pipeline**
    /// used for outbound `enqueue`:
    ///   - Block list (sender→recipient)
    ///   - Sensitive-data scanner (SSN / payment card)
    ///   - Harassment filter (strike increments + 3-strike auto-block)
    ///   - Attachment size / type allow-list
    ///   - Contact masking applied to the body before display
    ///
    /// If any guard fires, the message is **dropped** (not persisted, not delivered,
    /// not surfaced on the event stream) and the outcome is logged for audit.
    /// Harassment strikes from inbound peers still count toward the auto-block
    /// threshold so a misbehaving peer is cut off on this device too.
    private func acceptInbound(_ msg: Message) {
        // 1. Block list — inbound peer is blocked from the recipient's inbox.
        if blocks.contains("\(msg.fromUserId)|\(msg.toUserId)") {
            logger.warn(.transport, "inbound dropped blockedByRecipient id=\(msg.id) from=\(msg.fromUserId) to=\(msg.toUserId)")
            return
        }
        // 2. Sensitive data.
        if let kind = SensitiveDataScanner.scan(msg.body) {
            logger.warn(.transport, "inbound dropped sensitive kind=\(kind.rawValue) id=\(msg.id)")
            return
        }
        // 3. Harassment filter (strikes + auto-block so a misbehaving peer is cut off).
        if HarassmentFilter.isHarassing(msg.body) {
            let next = (harassmentStrikes[msg.fromUserId] ?? 0) + 1
            harassmentStrikes[msg.fromUserId] = next
            if next >= 3 {
                blocks.insert("\(msg.fromUserId)|\(msg.toUserId)")
            }
            logger.warn(.transport, "inbound dropped harassment id=\(msg.id) from=\(msg.fromUserId) strikes=\(next)")
            return
        }
        // 4. Attachment constraints.
        for a in msg.attachments {
            if a.sizeBytes > Self.maxAttachmentBytes {
                logger.warn(.transport, "inbound dropped attachmentTooLarge id=\(msg.id) attId=\(a.id)")
                return
            }
            switch a.kind {
            case .jpeg, .png, .pdf: break
            }
        }
        // 5. Contact masking — rebuild the message with the masked body so
        //    any PII in a peer-crafted payload is redacted before persistence.
        let masked = ContactMasker.mask(msg.body)
        var copy = Message(id: msg.id, fromUserId: msg.fromUserId, toUserId: msg.toUserId,
                           body: masked, attachments: msg.attachments,
                           createdAt: msg.createdAt,
                           deliveredAt: msg.deliveredAt ?? clock.now(),
                           threadId: msg.threadId)
        _ = copy   // keep compiler quiet if optimized out
        copy.deliveredAt = copy.deliveredAt ?? clock.now()
        delivered.append(copy)
        // Inbound delivery already happened via the transport layer; log the
        // audit-row failure so the missing persistence record is visible.
        do {
            try persist(copy)
        } catch {
            logger.error(.messaging,
                         "inbound persist failed id=\(copy.id) err=\(error) (message delivered; audit row lost)")
        }
        _events.onNext(.messageEnqueued(copy.id))
        logger.info(.transport, "inbound accepted id=\(copy.id) from=\(copy.fromUserId)")
    }

    // MARK: - Persistence

    private func persist(_ msg: Message) throws {
        guard let persistence else { return }
        do {
            let data = try JSONEncoder().encode(msg)
            try persistence.save(key: Self.persistencePrefix + msg.id, data: data)
        } catch {
            logger.error(.messaging, "persist failed id=\(msg.id)")
            throw MessagingError.persistenceFailed
        }
    }

    private func hydrate() {
        guard let persistence else { return }
        do {
            let entries = try persistence.loadAll(prefix: Self.persistencePrefix)
            let decoder = JSONDecoder()
            for entry in entries {
                if let msg = try? decoder.decode(Message.self, from: entry.data) {
                    if msg.deliveredAt != nil {
                        delivered.append(msg)
                    } else {
                        queued.append(msg)
                    }
                }
            }
        } catch {
            logger.error(.messaging, "hydrate failed err=\(error)")
        }
    }
}

// MARK: - Tiny regex helpers so the file stays self-contained.

extension String {
    func replacing(pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return self }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, options: [], range: range,
                                              withTemplate: replacement)
    }
}

extension NSRegularExpression {
    func firstMatch(in string: String) -> NSTextCheckingResult? {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return firstMatch(in: string, options: [], range: range)
    }
}
