import Foundation

public enum ContentKind: String, Codable, Sendable {
    case travelAdvisory
    case onboardOffer
}

public enum ContentStatus: String, Codable, Sendable {
    case draft
    case inReview
    case published
    case rejected
    case scheduled
    case rolledBack
}

/// A media reference embedded in rich content (images, PDFs, videos).
public struct MediaReference: Codable, Equatable, Sendable {
    public let id: String
    public let kind: AttachmentKind          // jpeg, png, pdf
    public let caption: String
    public let attachmentId: String?         // links to AttachmentService entry

    public init(id: String, kind: AttachmentKind, caption: String = "",
                attachmentId: String? = nil) {
        self.id = id; self.kind = kind; self.caption = caption
        self.attachmentId = attachmentId
    }
}

public struct ContentVersion: Codable, Equatable, Sendable {
    public let number: Int
    /// Rich-text body. Supports a simple markup subset (bold **..**, links [text](url)).
    public let body: String
    /// Media references embedded in this version.
    public let mediaRefs: [MediaReference]
    public let editedBy: String
    public let editedAt: Date

    public init(number: Int, body: String, mediaRefs: [MediaReference] = [],
                editedBy: String, editedAt: Date) {
        self.number = number; self.body = body; self.mediaRefs = mediaRefs
        self.editedBy = editedBy; self.editedAt = editedAt
    }
}

public struct ContentItem: Codable, Equatable, Sendable {
    public let id: String
    public let kind: ContentKind
    public var title: String
    public var tag: TaxonomyTag
    public var status: ContentStatus
    public var versions: [ContentVersion]
    public var currentVersion: Int
    public var publishAt: Date?
    public var reviewerId: String?

    public init(id: String, kind: ContentKind, title: String, tag: TaxonomyTag,
                status: ContentStatus = .draft, versions: [ContentVersion] = [],
                currentVersion: Int = 0, publishAt: Date? = nil, reviewerId: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.tag = tag
        self.status = status; self.versions = versions
        self.currentVersion = currentVersion; self.publishAt = publishAt
        self.reviewerId = reviewerId
    }
}

public enum ContentError: Error, Equatable {
    case notFound
    case invalidState
    case notReviewer
    case scheduleInPast
    case noPriorVersion
    case cannotApproveOwnDraft
    case persistenceFailed
}

/// Battery-optimized heavy processing hook: tasks are accepted but deferred unless
/// the device is in an "acceptable" power/inactivity state.
///
/// The prompt requires that heavy work (indexing, snapshotting, scheduled publishing,
/// media cleanup) runs only when the device is **on external power OR after user
/// inactivity**. `BatteryMonitor` surfaces both signals so `ContentPublishingService`
/// can enforce the contract without reaching into UIKit.
public protocol BatteryMonitor {
    var level: Double { get }           // 0.0 – 1.0
    var isLowPowerMode: Bool { get }
    /// `true` when the device is connected to external power (charging or full).
    var isCharging: Bool { get }
    /// `true` when the UI has been idle past the heavy-work inactivity threshold
    /// (typically ~60 s). `ContentPublishingService.processScheduled()` will refuse
    /// to run heavy work unless `isCharging == true` OR `isUserInactive == true`.
    var isUserInactive: Bool { get }
}

public final class FakeBattery: BatteryMonitor {
    public var level: Double
    public var isLowPowerMode: Bool
    public var isCharging: Bool
    public var isUserInactive: Bool
    public init(level: Double = 1.0, isLowPowerMode: Bool = false,
                isCharging: Bool = true, isUserInactive: Bool = true) {
        self.level = level
        self.isLowPowerMode = isLowPowerMode
        self.isCharging = isCharging
        self.isUserInactive = isUserInactive
    }
}

public final class ContentPublishingService {
    public static let maxVersions = 10
    public static let persistencePrefix = "content.item."

    private let clock: any Clock
    private let battery: BatteryMonitor
    private let persistence: PersistenceStore?
    private let logger: Logger
    private var items: [String: ContentItem] = [:]
    private(set) public var deferredProcessing: [String] = []

    public init(clock: any Clock,
                battery: BatteryMonitor,
                persistence: PersistenceStore? = nil,
                logger: Logger = SilentLogger()) {
        self.clock = clock
        self.battery = battery
        self.persistence = persistence
        self.logger = logger
        hydrate()
    }

    public func items(filter: TaxonomyTag = TaxonomyTag(), publishedOnly: Bool = true) -> [ContentItem] {
        items.values
            .filter { publishedOnly ? $0.status == .published : true }
            .filter { $0.tag.matches(filter) }
            .sorted { $0.id < $1.id }
    }

    /// Attachment ids currently referenced by any content version's media refs.
    /// Used by `AttachmentService.runRetentionSweep` so content media is preserved
    /// while the content item is live.
    public func referencedAttachmentIds() -> Set<String> {
        var ids: Set<String> = []
        for item in items.values {
            for version in item.versions {
                for ref in version.mediaRefs {
                    if let aid = ref.attachmentId { ids.insert(aid) }
                }
            }
        }
        return ids
    }

    /// Creates a new content draft. The caller must hold `.draftContent`.
    @discardableResult
    public func createDraft(id: String, kind: ContentKind, title: String, tag: TaxonomyTag,
                            body: String, mediaRefs: [MediaReference] = [],
                            editorId: String, actingUser: User) throws -> ContentItem {
        try RolePolicy.enforce(user: actingUser, .draftContent)
        var item = ContentItem(id: id, kind: kind, title: title, tag: tag)
        let version = ContentVersion(number: 1, body: body, mediaRefs: mediaRefs,
                                     editedBy: editorId, editedAt: clock.now())
        item.versions = [version]
        item.currentVersion = 1
        items[id] = item
        try persist(item)
        logger.info(.content, "createDraft id=\(id) editor=\(editorId)")
        return item
    }

    /// Edits an existing draft or rejected item. The caller must hold `.draftContent`.
    @discardableResult
    public func edit(id: String, body: String, mediaRefs: [MediaReference] = [],
                     editorId: String, actingUser: User) throws -> ContentItem {
        try RolePolicy.enforce(user: actingUser, .draftContent)
        guard var item = items[id] else { throw ContentError.notFound }
        guard item.status == .draft || item.status == .rejected else {
            throw ContentError.invalidState
        }
        let nextNumber = item.versions.map { $0.number }.max()! + 1
        var versions = item.versions
        versions.append(ContentVersion(number: nextNumber, body: body, mediaRefs: mediaRefs,
                                       editedBy: editorId, editedAt: clock.now()))
        if versions.count > Self.maxVersions {
            versions.removeFirst(versions.count - Self.maxVersions)
        }
        item.versions = versions
        item.currentVersion = nextNumber
        items[id] = item
        try persist(item)
        logger.info(.content, "edit id=\(id) version=\(nextNumber)")
        return item
    }

    /// Moves a draft to in-review. Requires `.draftContent` — only the editor of the
    /// draft (or another user with the draft permission) may submit it for review.
    public func submitForReview(id: String, actingUser: User) throws {
        try RolePolicy.enforce(user: actingUser, .draftContent)
        guard var item = items[id] else { throw ContentError.notFound }
        guard item.status == .draft || item.status == .rejected else {
            throw ContentError.invalidState
        }
        item.status = .inReview
        items[id] = item
        try persist(item)
        logger.info(.content, "submitForReview id=\(id) actor=\(actingUser.id)")
    }

    public func approve(id: String, reviewer: User) throws {
        try RolePolicy.enforce(user: reviewer, .publishContent)
        guard var item = items[id] else { throw ContentError.notFound }
        guard item.status == .inReview else { throw ContentError.invalidState }
        // Separation of duties: non-admin reviewers cannot approve their own draft.
        if reviewer.role != .administrator,
           let originalEditor = item.versions.first?.editedBy,
           originalEditor == reviewer.id {
            throw ContentError.cannotApproveOwnDraft
        }
        item.status = .published
        item.reviewerId = reviewer.id
        items[id] = item
        try persist(item)
        logger.info(.content, "approve id=\(id) reviewer=\(reviewer.id)")
    }

    public func reject(id: String, reviewer: User) throws {
        try RolePolicy.enforce(user: reviewer, .publishContent)
        guard var item = items[id] else { throw ContentError.notFound }
        guard item.status == .inReview else { throw ContentError.invalidState }
        item.status = .rejected
        item.reviewerId = reviewer.id
        items[id] = item
        try persist(item)
        logger.info(.content, "reject id=\(id) reviewer=\(reviewer.id)")
    }

    public func schedule(id: String, at date: Date, reviewer: User) throws {
        try RolePolicy.enforce(user: reviewer, .publishContent)
        guard var item = items[id] else { throw ContentError.notFound }
        guard item.status == .inReview else { throw ContentError.invalidState }
        guard date > clock.now() else { throw ContentError.scheduleInPast }
        item.status = .scheduled
        item.publishAt = date
        item.reviewerId = reviewer.id
        items[id] = item
        try persist(item)
        logger.info(.content, "schedule id=\(id) at=\(date)")
    }

    /// Background-task entry point: publish scheduled items whose time has arrived.
    ///
    /// Enforces the prompt's **"heavy work only on power OR after user inactivity"**
    /// contract. Work is deferred when ANY of the following holds:
    ///   - Low Power Mode is active.
    ///   - Battery level is below 20% and the device is not charging.
    ///   - The device is neither charging nor in the user-inactive state.
    ///
    /// Deferred items are captured in `deferredProcessing` and drain on the next
    /// call once the gating condition clears.
    ///
    /// Error surfacing: failed publishes (persistence errors, encoding errors)
    /// are rolled back to `.scheduled`, re-added to `deferredProcessing`, and
    /// reported via `lastProcessScheduledErrors` so a caller polling that
    /// property can detect and escalate durability incidents instead of
    /// observing only a silently-smaller published list.
    @discardableResult
    public func processScheduled() -> [String] {
        lastProcessScheduledErrors = [:]
        let due = items.values
            .filter { $0.status == .scheduled && ($0.publishAt ?? .distantFuture) <= clock.now() }
            .map { $0.id }

        if let deferReason = heavyWorkDeferReason() {
            deferredProcessing = due
            logger.info(.content, "processScheduled deferred=\(due.count) reason=\(deferReason)")
            return []
        }

        var published: [String] = []
        var failed: [String] = []
        var errors: [String: Error] = [:]
        for (id, var item) in items {
            if item.status == .scheduled, let at = item.publishAt, at <= clock.now() {
                let prior = items[id]
                item.status = .published
                items[id] = item
                do {
                    try persist(item)
                    published.append(id)
                } catch {
                    // Roll back in-memory publication so the item stays
                    // `.scheduled` and the next sweep retries instead of
                    // reporting a publish that never durably landed.
                    items[id] = prior
                    failed.append(id)
                    errors[id] = error
                    logger.error(.content, "processScheduled persist failed id=\(id) err=\(error)")
                }
            }
        }
        // Re-defer any items whose publish failed so the next tick re-attempts
        // them once the storage layer is healthy again.
        deferredProcessing = failed
        lastProcessScheduledErrors = errors
        logger.info(.content, "processScheduled published=\(published.count) redeferred=\(failed.count)")
        return published.sorted()
    }

    /// Map of item id → error from the most recent `processScheduled()` call.
    /// Empty when the last run had no failures (or was deferred by the
    /// power/inactivity gate). Kept alongside `deferredProcessing` so callers
    /// can distinguish "deferred because battery" from "deferred because
    /// persistence failed" without scanning logs.
    public private(set) var lastProcessScheduledErrors: [String: Error] = [:]

    /// Returns `nil` if heavy work may run now, or a short reason string if it must
    /// be deferred. Centralizes the power / inactivity contract.
    private func heavyWorkDeferReason() -> String? {
        if battery.isLowPowerMode { return "lowPowerMode" }
        if battery.level < 0.2 && !battery.isCharging { return "lowBatteryNotCharging" }
        if !battery.isCharging && !battery.isUserInactive { return "notOnPowerAndUserActive" }
        return nil
    }

    /// Reverts the most recent version of an item. Requires `.draftContent` or `.publishContent`.
    ///
    /// If the item is currently `.published`, rollback restores the *prior version*
    /// but keeps the item customer-visible (status remains `.published`). Rolling
    /// back from other states transitions to `.rolledBack` so editors can continue
    /// working the draft without surfacing a partially-edited item to customers.
    public func rollback(id: String, actingUser: User) throws {
        guard RolePolicy.can(actingUser.role, .draftContent)
           || RolePolicy.can(actingUser.role, .publishContent) else {
            throw AuthorizationError.forbidden(required: .draftContent)
        }
        guard var item = items[id] else { throw ContentError.notFound }
        guard item.versions.count >= 2 else { throw ContentError.noPriorVersion }
        let wasPublished = (item.status == .published)
        item.versions.removeLast()
        item.currentVersion = item.versions.last!.number
        // Preserve customer-visible publication when rolling back a published item;
        // otherwise mark as rolledBack so the editor flow can continue.
        item.status = wasPublished ? .published : .rolledBack
        items[id] = item
        try persist(item)
        logger.info(.content, "rollback id=\(id) actor=\(actingUser.id) preservedPublished=\(wasPublished)")
    }

    public func get(_ id: String) -> ContentItem? { items[id] }

    // MARK: - Persistence

    private func persist(_ item: ContentItem) throws {
        guard let persistence else { return }
        do {
            let data = try JSONEncoder().encode(item)
            try persistence.save(key: Self.persistencePrefix + item.id, data: data)
        } catch {
            logger.error(.content, "persist failed id=\(item.id) err=\(error)")
            throw ContentError.persistenceFailed
        }
    }

    private func hydrate() {
        guard let persistence else { return }
        do {
            let entries = try persistence.loadAll(prefix: Self.persistencePrefix)
            let decoder = JSONDecoder()
            for entry in entries {
                if let it = try? decoder.decode(ContentItem.self, from: entry.data) {
                    items[it.id] = it
                }
            }
        } catch {
            logger.error(.content, "hydrate failed err=\(error)")
        }
    }
}
