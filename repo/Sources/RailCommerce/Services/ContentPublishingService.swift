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

public struct ContentVersion: Codable, Equatable, Sendable {
    public let number: Int
    public let body: String
    public let editedBy: String
    public let editedAt: Date
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
}

/// Battery-optimized heavy processing hook: tasks are accepted but deferred when low-battery.
public protocol BatteryMonitor {
    var level: Double { get }          // 0.0 - 1.0
    var isLowPowerMode: Bool { get }
}

public final class FakeBattery: BatteryMonitor {
    public var level: Double
    public var isLowPowerMode: Bool
    public init(level: Double = 1.0, isLowPowerMode: Bool = false) {
        self.level = level
        self.isLowPowerMode = isLowPowerMode
    }
}

public final class ContentPublishingService {
    public static let maxVersions = 10

    private let clock: Clock
    private let battery: BatteryMonitor
    private var items: [String: ContentItem] = [:]
    private(set) public var deferredProcessing: [String] = []

    public init(clock: Clock, battery: BatteryMonitor) {
        self.clock = clock
        self.battery = battery
    }

    public func items(filter: TaxonomyTag = TaxonomyTag(), publishedOnly: Bool = true) -> [ContentItem] {
        items.values
            .filter { publishedOnly ? $0.status == .published : true }
            .filter { $0.tag.matches(filter) }
            .sorted { $0.id < $1.id }
    }

    /// Creates a new content draft (no role check; use the `actingUser:` overload to enforce `.draftContent`).
    @discardableResult
    public func createDraft(id: String, kind: ContentKind, title: String, tag: TaxonomyTag,
                            body: String, editorId: String) -> ContentItem {
        var item = ContentItem(id: id, kind: kind, title: title, tag: tag)
        let version = ContentVersion(number: 1, body: body, editedBy: editorId, editedAt: clock.now())
        item.versions = [version]
        item.currentVersion = 1
        items[id] = item
        return item
    }

    /// Creates a new content draft after verifying the caller holds `.draftContent`.
    @discardableResult
    public func createDraft(id: String, kind: ContentKind, title: String, tag: TaxonomyTag,
                            body: String, editorId: String, actingUser: User) throws -> ContentItem {
        try RolePolicy.enforce(user: actingUser, .draftContent)
        return createDraft(id: id, kind: kind, title: title, tag: tag,
                           body: body, editorId: editorId)
    }

    /// Edits an existing draft or rejected item.
    /// - Parameter actingUser: When provided must hold `.draftContent`.
    @discardableResult
    public func edit(id: String, body: String, editorId: String, actingUser: User? = nil) throws -> ContentItem {
        if let user = actingUser {
            try RolePolicy.enforce(user: user, .draftContent)
        }
        guard var item = items[id] else { throw ContentError.notFound }
        guard item.status == .draft || item.status == .rejected else {
            throw ContentError.invalidState
        }
        let nextNumber = item.versions.map { $0.number }.max()! + 1
        var versions = item.versions
        versions.append(ContentVersion(number: nextNumber, body: body,
                                       editedBy: editorId, editedAt: clock.now()))
        if versions.count > Self.maxVersions {
            versions.removeFirst(versions.count - Self.maxVersions)
        }
        item.versions = versions
        item.currentVersion = nextNumber
        items[id] = item
        return item
    }

    public func submitForReview(id: String) throws {
        guard var item = items[id] else { throw ContentError.notFound }
        guard item.status == .draft || item.status == .rejected else {
            throw ContentError.invalidState
        }
        item.status = .inReview
        items[id] = item
    }

    public func approve(id: String, reviewer: User) throws {
        guard reviewer.role == .contentReviewer || reviewer.role == .administrator else {
            throw ContentError.notReviewer
        }
        guard var item = items[id] else { throw ContentError.notFound }
        guard item.status == .inReview else { throw ContentError.invalidState }
        item.status = .published
        item.reviewerId = reviewer.id
        items[id] = item
    }

    public func reject(id: String, reviewer: User) throws {
        guard reviewer.role == .contentReviewer || reviewer.role == .administrator else {
            throw ContentError.notReviewer
        }
        guard var item = items[id] else { throw ContentError.notFound }
        guard item.status == .inReview else { throw ContentError.invalidState }
        item.status = .rejected
        item.reviewerId = reviewer.id
        items[id] = item
    }

    public func schedule(id: String, at date: Date, reviewer: User) throws {
        guard reviewer.role == .contentReviewer || reviewer.role == .administrator else {
            throw ContentError.notReviewer
        }
        guard var item = items[id] else { throw ContentError.notFound }
        guard item.status == .inReview else { throw ContentError.invalidState }
        guard date > clock.now() else { throw ContentError.scheduleInPast }
        item.status = .scheduled
        item.publishAt = date
        item.reviewerId = reviewer.id
        items[id] = item
    }

    /// Background-task entry point: publish scheduled items whose time has arrived.
    @discardableResult
    public func processScheduled() -> [String] {
        if battery.isLowPowerMode || battery.level < 0.2 {
            deferredProcessing = items.values
                .filter { $0.status == .scheduled && $0.publishAt! <= clock.now() }
                .map { $0.id }
            return []
        }
        var published: [String] = []
        for (id, var item) in items {
            if item.status == .scheduled, let at = item.publishAt, at <= clock.now() {
                item.status = .published
                items[id] = item
                published.append(id)
            }
        }
        deferredProcessing = []
        return published.sorted()
    }

    public func rollback(id: String) throws {
        guard var item = items[id] else { throw ContentError.notFound }
        guard item.versions.count >= 2 else { throw ContentError.noPriorVersion }
        item.versions.removeLast()
        item.currentVersion = item.versions.last!.number
        item.status = .rolledBack
        items[id] = item
    }

    public func get(_ id: String) -> ContentItem? { items[id] }
}
