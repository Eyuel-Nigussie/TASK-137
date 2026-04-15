import Foundation
import RxSwift

public enum AfterSalesKind: String, Codable, Sendable {
    case returnAndRefund
    case refundOnly
    case exchange
}

public enum AfterSalesReason: String, Codable, Sendable {
    case defective
    case wrongItem
    case notAsDescribed
    case changedMind
    case late
    case other
}

public enum AfterSalesStatus: String, Codable, Sendable {
    case pending
    case awaitingCustomer
    case approved
    case rejected
    case closed
    case autoApproved
    case autoRejected
}

public struct AfterSalesRequest: Codable, Equatable, Sendable {
    public let id: String
    public let orderId: String
    public let kind: AfterSalesKind
    public let reason: AfterSalesReason
    public var status: AfterSalesStatus
    public let createdAt: Date
    public let serviceDate: Date
    public let amountCents: Int
    public var photoAttachmentIds: [String]
    public var disputedAt: Date?
    public var firstResponseAt: Date?
    public var resolvedAt: Date?

    public init(id: String, orderId: String, kind: AfterSalesKind, reason: AfterSalesReason,
                status: AfterSalesStatus = .pending, createdAt: Date, serviceDate: Date,
                amountCents: Int, photoAttachmentIds: [String] = [],
                disputedAt: Date? = nil, firstResponseAt: Date? = nil, resolvedAt: Date? = nil) {
        self.id = id; self.orderId = orderId; self.kind = kind; self.reason = reason
        self.status = status; self.createdAt = createdAt; self.serviceDate = serviceDate
        self.amountCents = amountCents; self.photoAttachmentIds = photoAttachmentIds
        self.disputedAt = disputedAt; self.firstResponseAt = firstResponseAt
        self.resolvedAt = resolvedAt
    }
}

public enum AfterSalesError: Error, Equatable {
    case notFound
    case alreadyClosed
    case missingPhoto
    case cameraDenied
}

public protocol CameraPermission {
    var isGranted: Bool { get }
}

public final class FakeCamera: CameraPermission {
    public var isGranted: Bool
    public init(granted: Bool) { self.isGranted = granted }
}

public struct AfterSalesSLA: Equatable, Sendable {
    public let firstResponseDue: Date
    public let resolutionDue: Date
    public let firstResponseBreached: Bool
    public let resolutionBreached: Bool
}

/// Local-only notification sink used to satisfy "closed-loop messaging and local notifications only".
public final class LocalNotificationBus {
    private(set) public var events: [String] = []
    public init() {}
    public func post(_ event: String) { events.append(event) }
    public func clear() { events.removeAll() }
}

public final class AfterSalesService {
    public static let firstResponseHours = 4
    public static let resolutionDays = 3
    public static let autoApproveUnderCents = 2_500
    public static let autoApproveAfterHours = 48
    public static let autoRejectAfterDays = 14

    private let clock: Clock
    private let camera: CameraPermission
    private let notifier: LocalNotificationBus
    private var requestStore: [String: AfterSalesRequest] = [:]

    private let _events = PublishSubject<AfterSalesEvent>()
    /// Observable stream of after-sales lifecycle events.
    public var events: Observable<AfterSalesEvent> { _events.asObservable() }

    public init(clock: Clock, camera: CameraPermission, notifier: LocalNotificationBus) {
        self.clock = clock
        self.camera = camera
        self.notifier = notifier
    }

    /// Opens a new after-sales request.
    /// - Parameter actingUser: Must hold `.manageAfterSales` when provided.
    @discardableResult
    public func open(_ req: AfterSalesRequest, actingUser: User? = nil) throws -> AfterSalesRequest {
        if let user = actingUser {
            try RolePolicy.enforce(user: user, .manageAfterSales)
        }
        if req.kind != .refundOnly && req.photoAttachmentIds.isEmpty {
            if !camera.isGranted { throw AfterSalesError.cameraDenied }
            throw AfterSalesError.missingPhoto
        }
        requestStore[req.id] = req
        notifier.post("afterSales.opened:\(req.id)")
        _events.onNext(.requestOpened(req.id))
        return req
    }

    public func respond(id: String) throws {
        guard var r = requestStore[id] else { throw AfterSalesError.notFound }
        guard r.status != .closed else { throw AfterSalesError.alreadyClosed }
        r.firstResponseAt = clock.now()
        r.status = .awaitingCustomer
        requestStore[id] = r
        notifier.post("afterSales.firstResponse:\(id)")
    }

    /// Approves a request.
    /// - Parameter actingUser: Must hold `.handleServiceTickets` when provided.
    public func approve(id: String, actingUser: User? = nil) throws {
        if let user = actingUser {
            try RolePolicy.enforce(user: user, .handleServiceTickets)
        }
        guard var r = requestStore[id] else { throw AfterSalesError.notFound }
        r.status = .approved
        r.resolvedAt = clock.now()
        requestStore[id] = r
        notifier.post("afterSales.approved:\(id)")
        _events.onNext(.requestResolved(id, .approved))
    }

    /// Rejects a request.
    /// - Parameter actingUser: Must hold `.handleServiceTickets` when provided.
    public func reject(id: String, actingUser: User? = nil) throws {
        if let user = actingUser {
            try RolePolicy.enforce(user: user, .handleServiceTickets)
        }
        guard var r = requestStore[id] else { throw AfterSalesError.notFound }
        r.status = .rejected
        r.resolvedAt = clock.now()
        requestStore[id] = r
        notifier.post("afterSales.rejected:\(id)")
        _events.onNext(.requestResolved(id, .rejected))
    }

    public func dispute(id: String) throws {
        guard var r = requestStore[id] else { throw AfterSalesError.notFound }
        r.disputedAt = clock.now()
        requestStore[id] = r
        notifier.post("afterSales.disputed:\(id)")
    }

    public func close(id: String) throws {
        guard var r = requestStore[id] else { throw AfterSalesError.notFound }
        r.status = .closed
        r.resolvedAt = r.resolvedAt ?? clock.now()
        requestStore[id] = r
        notifier.post("afterSales.closed:\(id)")
    }

    public func all() -> [AfterSalesRequest] {
        requestStore.values.sorted { $0.id < $1.id }
    }

    public func get(_ id: String) -> AfterSalesRequest? { requestStore[id] }

    /// Returns all after-sales requests associated with `orderId`, sorted by request ID.
    public func requests(for orderId: String) -> [AfterSalesRequest] {
        requestStore.values.filter { $0.orderId == orderId }.sorted { $0.id < $1.id }
    }

    public func sla(for id: String) -> AfterSalesSLA? {
        guard let r = requestStore[id] else { return nil }
        let responseDue = BusinessTime.add(businessHours: Self.firstResponseHours, to: r.createdAt)
        let resolutionDue = BusinessTime.add(businessDays: Self.resolutionDays, to: r.createdAt)
        let now = clock.now()
        let responseBreached = (r.firstResponseAt ?? now) > responseDue
        let resolutionBreached = (r.resolvedAt ?? now) > resolutionDue
        return AfterSalesSLA(firstResponseDue: responseDue, resolutionDue: resolutionDue,
                             firstResponseBreached: responseBreached,
                             resolutionBreached: resolutionBreached)
    }

    /// Runs automation rules. Called periodically (in production via a background task).
    @discardableResult
    public func runAutomation() -> [String] {
        var changed: [String] = []
        let now = clock.now()
        for var r in requestStore.values {
            if r.status == .closed || r.status == .autoApproved || r.status == .autoRejected {
                continue
            }

            // Auto-reject if 14+ days past service date.
            if let daysPast = Calendar.utc.dateComponents([.day], from: r.serviceDate, to: now).day,
               daysPast >= Self.autoRejectAfterDays {
                r.status = .autoRejected
                r.resolvedAt = now
                requestStore[r.id] = r
                notifier.post("afterSales.autoRejected:\(r.id)")
                changed.append(r.id)
                continue
            }

            // Auto-approve refund-only under $25 after 48h without dispute.
            let elapsedHours = now.timeIntervalSince(r.createdAt) / 3600
            if r.kind == .refundOnly,
               r.amountCents < Self.autoApproveUnderCents,
               r.disputedAt == nil,
               elapsedHours >= Double(Self.autoApproveAfterHours) {
                r.status = .autoApproved
                r.resolvedAt = now
                requestStore[r.id] = r
                notifier.post("afterSales.autoApproved:\(r.id)")
                changed.append(r.id)
            }
        }
        return changed
    }
}
