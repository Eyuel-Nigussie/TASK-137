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

    public init(id: String, fromUserId: String, toUserId: String, body: String,
                attachments: [MessageAttachment] = [], createdAt: Date, deliveredAt: Date? = nil) {
        self.id = id; self.fromUserId = fromUserId; self.toUserId = toUserId
        self.body = body; self.attachments = attachments
        self.createdAt = createdAt; self.deliveredAt = deliveredAt
    }
}

public enum MessagingError: Error, Equatable {
    case sensitiveDataBlocked(kind: SensitiveKind)
    case attachmentTooLarge
    case attachmentTypeNotAllowed
    case harassmentBlocked
    case blockedByRecipient
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

    private let clock: Clock
    private var queued: [Message] = []
    private var delivered: [Message] = []
    private var blocks: Set<String> = [] // "from|to" pairs
    private var harassmentStrikes: [String: Int] = [:]

    private let _events = PublishSubject<MessagingEvent>()
    /// Observable stream of messaging lifecycle events.
    public var events: Observable<MessagingEvent> { _events.asObservable() }

    public init(clock: Clock) { self.clock = clock }

    public var queue: [Message] { queued }
    public var deliveredMessages: [Message] { delivered }

    public func block(from: String, to: String) { blocks.insert("\(from)|\(to)") }
    public func unblock(from: String, to: String) { blocks.remove("\(from)|\(to)") }

    /// Returns all delivered messages sent by `userId`.
    public func messages(from userId: String) -> [Message] {
        delivered.filter { $0.fromUserId == userId }
    }

    /// Returns all delivered messages addressed to `userId`.
    public func messages(to userId: String) -> [Message] {
        delivered.filter { $0.toUserId == userId }
    }

    /// Enqueues a message after applying safety checks and contact masking.
    /// - Parameter actingUser: When provided, the caller's role is validated against
    ///   the `browseContent` permission (held by every valid role in the system).
    @discardableResult
    public func enqueue(id: String, from: String, to: String,
                        body: String, attachments: [MessageAttachment] = [],
                        actingUser: User? = nil) throws -> Message {
        if let user = actingUser {
            try RolePolicy.enforce(user: user, .browseContent)
        }
        if blocks.contains("\(from)|\(to)") {
            throw MessagingError.blockedByRecipient
        }
        if let kind = SensitiveDataScanner.scan(body) {
            throw MessagingError.sensitiveDataBlocked(kind: kind)
        }
        if HarassmentFilter.isHarassing(body) {
            let next = (harassmentStrikes[from] ?? 0) + 1
            harassmentStrikes[from] = next
            if next >= 3 {
                blocks.insert("\(from)|\(to)")
            }
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
                          attachments: attachments, createdAt: clock.now())
        queued.append(msg)
        _events.onNext(.messageEnqueued(id))
        return msg
    }

    /// Flush queued messages to the delivered set (simulating offline sync).
    @discardableResult
    public func drainQueue() -> [Message] {
        let now = clock.now()
        let toDeliver = queued.map { msg -> Message in
            var copy = msg
            copy.deliveredAt = now
            return copy
        }
        delivered.append(contentsOf: toDeliver)
        queued.removeAll()
        _events.onNext(.queueDrained(toDeliver.count))
        return toDeliver
    }

    public func strikes(for user: String) -> Int { harassmentStrikes[user] ?? 0 }
    public func isBlocked(from: String, to: String) -> Bool { blocks.contains("\(from)|\(to)") }
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
