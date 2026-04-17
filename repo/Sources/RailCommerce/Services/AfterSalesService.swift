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
    /// The user who opened this request. Set automatically by `open(_:actingUser:)`.
    public var createdByUserId: String?
    public var photoAttachmentIds: [String]
    public var disputedAt: Date?
    public var firstResponseAt: Date?
    public var resolvedAt: Date?

    public init(id: String, orderId: String, kind: AfterSalesKind, reason: AfterSalesReason,
                status: AfterSalesStatus = .pending, createdAt: Date, serviceDate: Date,
                amountCents: Int, createdByUserId: String? = nil,
                photoAttachmentIds: [String] = [],
                disputedAt: Date? = nil, firstResponseAt: Date? = nil, resolvedAt: Date? = nil) {
        self.id = id; self.orderId = orderId; self.kind = kind; self.reason = reason
        self.status = status; self.createdAt = createdAt; self.serviceDate = serviceDate
        self.amountCents = amountCents; self.createdByUserId = createdByUserId
        self.photoAttachmentIds = photoAttachmentIds
        self.disputedAt = disputedAt; self.firstResponseAt = firstResponseAt
        self.resolvedAt = resolvedAt
    }
}

public enum AfterSalesError: Error, Equatable {
    case notFound
    case alreadyClosed
    case missingPhoto
    case cameraDenied
    case persistenceFailed
    case orderNotOwned
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
/// The app layer may set `onPost` to forward events to `UNUserNotificationCenter`.
public final class LocalNotificationBus {
    private(set) public var events: [String] = []
    /// Called on every `post(_:)`. Set by the app target to forward events to OS notifications.
    public var onPost: ((String) -> Void)?
    public init() {}
    public func post(_ event: String) {
        events.append(event)
        onPost?(event)
    }
    public func clear() { events.removeAll() }
}

public final class AfterSalesService {
    public static let firstResponseHours = 4
    public static let resolutionDays = 3
    public static let autoApproveUnderCents = 2_500
    public static let autoApproveAfterHours = 48
    public static let autoRejectAfterDays = 14
    public static let persistencePrefix = "afterSales.req."

    /// Closure that validates whether a user owns a given orderId. Injected by the
    /// composition root so `AfterSalesService` does not depend on `CheckoutService`.
    /// Returns `true` if the user is allowed to open a request for that order.
    public typealias OrderOwnershipValidator = (_ orderId: String, _ userId: String) -> Bool

    private let clock: any Clock
    private let camera: CameraPermission
    private let notifier: LocalNotificationBus
    private let persistence: PersistenceStore?
    private let logger: Logger
    private let orderOwnershipValidator: OrderOwnershipValidator
    private var requestStore: [String: AfterSalesRequest] = [:]
    /// Optional link into the messaging layer. When set, `postCaseMessage`
    /// forwards conversation messages scoped to a specific request id so the
    /// closed-loop CS thread lives under the messaging service and benefits
    /// from its filters/redaction/transport. Set by the composition root.
    public var messenger: MessagingService?

    private let _events = PublishSubject<AfterSalesEvent>()
    /// Observable stream of after-sales lifecycle events.
    public var events: Observable<AfterSalesEvent> { _events.asObservable() }

    /// - Parameter orderOwnershipValidator: returns true when the user owns the orderId
    ///   or is a privileged staff role. Defaults to always-true for backward compat in tests.
    public init(clock: any Clock,
                camera: CameraPermission,
                notifier: LocalNotificationBus,
                persistence: PersistenceStore? = nil,
                logger: Logger = SilentLogger(),
                orderOwnershipValidator: @escaping OrderOwnershipValidator = { _, _ in true }) {
        self.clock = clock
        self.camera = camera
        self.notifier = notifier
        self.persistence = persistence
        self.logger = logger
        self.orderOwnershipValidator = orderOwnershipValidator
        hydrate()
    }

    // MARK: - Closed-loop case messaging

    /// Posts a message into the conversation thread attached to an after-sales
    /// request. The thread uses `request.id` as its `threadId`. Visibility:
    ///   - The customer who owns the request (`createdByUserId`) may post / read.
    ///   - CSR / admin may post / read any request's thread.
    ///   - Any other user is rejected.
    ///
    /// - Parameter to: The recipient's user id. Typically the request owner
    ///   (customer) sends to a CSR id or vice-versa.
    @discardableResult
    public func postCaseMessage(requestId: String, to: String, body: String,
                                actingUser: User) throws -> Message {
        guard let req = requestStore[requestId] else { throw AfterSalesError.notFound }
        let isPrivileged = RolePolicy.can(actingUser.role, .handleServiceTickets)
            || RolePolicy.can(actingUser.role, .configureSystem)
        if !isPrivileged && req.createdByUserId != actingUser.id {
            logger.warn(.afterSales, "postCaseMessage forbidden actor=\(actingUser.id) request=\(requestId)")
            throw AfterSalesError.orderNotOwned
        }
        guard let messenger = messenger else {
            logger.error(.afterSales, "postCaseMessage no messenger wired request=\(requestId)")
            throw AfterSalesError.persistenceFailed
        }
        let msg = try messenger.enqueue(
            id: UUID().uuidString,
            from: actingUser.id,
            to: to,
            body: body,
            actingUser: actingUser,
            threadId: requestId
        )
        notifier.post("afterSales.caseMessage:\(requestId)")
        logger.info(.afterSales, "caseMessage request=\(requestId) from=\(actingUser.id) to=\(to)")
        return msg
    }

    /// Returns the conversation thread for an after-sales request.
    /// Visibility matches `postCaseMessage`.
    public func caseMessages(requestId: String, actingUser: User) throws -> [Message] {
        guard let req = requestStore[requestId] else { throw AfterSalesError.notFound }
        let isPrivileged = RolePolicy.can(actingUser.role, .handleServiceTickets)
            || RolePolicy.can(actingUser.role, .configureSystem)
        if !isPrivileged && req.createdByUserId != actingUser.id {
            throw AfterSalesError.orderNotOwned
        }
        guard let messenger = messenger else { return [] }
        return try messenger.messages(inThread: requestId, actingUser: actingUser)
    }

    /// Opens a new after-sales request.
    /// - Parameter actingUser: Must hold `.manageAfterSales`. For non-staff users,
    ///   the order must be owned by the acting user (enforced via the injected validator).
    @discardableResult
    public func open(_ req: AfterSalesRequest, actingUser: User) throws -> AfterSalesRequest {
        try RolePolicy.enforce(user: actingUser, .manageAfterSales)
        // Enforce order ownership for customers. Staff (CSR/admin) bypass.
        if !RolePolicy.can(actingUser.role, .handleServiceTickets)
           && !RolePolicy.can(actingUser.role, .configureSystem) {
            guard orderOwnershipValidator(req.orderId, actingUser.id) else {
                logger.warn(.afterSales, "open orderNotOwned orderId=\(req.orderId) actor=\(actingUser.id)")
                throw AfterSalesError.orderNotOwned
            }
        }
        if req.kind != .refundOnly && req.photoAttachmentIds.isEmpty {
            if !camera.isGranted { throw AfterSalesError.cameraDenied }
            throw AfterSalesError.missingPhoto
        }
        var stamped = req
        stamped.createdByUserId = actingUser.id
        requestStore[stamped.id] = stamped
        try persist(stamped)
        notifier.post("afterSales.opened:\(stamped.id)")
        _events.onNext(.requestOpened(stamped.id))
        logger.info(.afterSales, "open id=\(stamped.id) kind=\(stamped.kind.rawValue) amount=\(stamped.amountCents)")
        return stamped
    }

    /// Records the first response. Requires `.handleServiceTickets` (CSR/admin).
    public func respond(id: String, actingUser: User) throws {
        try RolePolicy.enforce(user: actingUser, .handleServiceTickets)
        guard var r = requestStore[id] else { throw AfterSalesError.notFound }
        guard r.status != .closed else { throw AfterSalesError.alreadyClosed }
        r.firstResponseAt = clock.now()
        r.status = .awaitingCustomer
        requestStore[id] = r
        try persist(r)
        notifier.post("afterSales.firstResponse:\(id)")
        logger.info(.afterSales, "respond id=\(id) actor=\(actingUser.id)")
    }

    /// Approves a request.
    /// - Parameter actingUser: Must hold `.handleServiceTickets`; otherwise `AuthorizationError.forbidden` is thrown.
    public func approve(id: String, actingUser: User) throws {
        try RolePolicy.enforce(user: actingUser, .handleServiceTickets)
        guard var r = requestStore[id] else { throw AfterSalesError.notFound }
        r.status = .approved
        r.resolvedAt = clock.now()
        requestStore[id] = r
        try persist(r)
        notifier.post("afterSales.approved:\(id)")
        _events.onNext(.requestResolved(id, .approved))
        logger.info(.afterSales, "approve id=\(id) actor=\(actingUser.id)")
    }

    /// Rejects a request.
    /// - Parameter actingUser: Must hold `.handleServiceTickets`; otherwise `AuthorizationError.forbidden` is thrown.
    public func reject(id: String, actingUser: User) throws {
        try RolePolicy.enforce(user: actingUser, .handleServiceTickets)
        guard var r = requestStore[id] else { throw AfterSalesError.notFound }
        r.status = .rejected
        r.resolvedAt = clock.now()
        requestStore[id] = r
        try persist(r)
        notifier.post("afterSales.rejected:\(id)")
        _events.onNext(.requestResolved(id, .rejected))
        logger.info(.afterSales, "reject id=\(id) actor=\(actingUser.id)")
    }

    /// Disputes a pending request.
    ///
    /// Authorization is layered:
    /// 1. Function-level: caller must hold `.manageAfterSales` (customer / CSR / admin).
    /// 2. **Object-level: the caller must be the request's owner OR hold a privileged
    ///    role (CSR `.handleServiceTickets` or admin `.configureSystem`).** This prevents
    ///    a customer with a guessed/enumerated request id from disputing another
    ///    customer's request — which would otherwise short-circuit the 48h auto-approve
    ///    path and cross user-data boundaries.
    public func dispute(id: String, actingUser: User) throws {
        try RolePolicy.enforce(user: actingUser, .manageAfterSales)
        guard var r = requestStore[id] else { throw AfterSalesError.notFound }
        // Object-level ownership: customers can only dispute their own requests.
        // Staff roles (CSR/admin) may dispute on behalf of the customer.
        let isPrivileged = RolePolicy.can(actingUser.role, .handleServiceTickets)
            || RolePolicy.can(actingUser.role, .configureSystem)
        if !isPrivileged && r.createdByUserId != actingUser.id {
            logger.warn(.afterSales, "dispute forbidden actor=\(actingUser.id) ownerId=\(r.createdByUserId ?? "nil") id=\(id)")
            throw AfterSalesError.orderNotOwned
        }
        r.disputedAt = clock.now()
        requestStore[id] = r
        try persist(r)
        notifier.post("afterSales.disputed:\(id)")
        logger.info(.afterSales, "dispute id=\(id) actor=\(actingUser.id)")
    }

    /// Closes a request permanently. Requires `.handleServiceTickets` (CSR/admin).
    public func close(id: String, actingUser: User) throws {
        try RolePolicy.enforce(user: actingUser, .handleServiceTickets)
        guard var r = requestStore[id] else { throw AfterSalesError.notFound }
        r.status = .closed
        r.resolvedAt = r.resolvedAt ?? clock.now()
        requestStore[id] = r
        try persist(r)
        notifier.post("afterSales.closed:\(id)")
        logger.info(.afterSales, "close id=\(id) actor=\(actingUser.id)")
    }

    // MARK: - Persistence

    private func persist(_ req: AfterSalesRequest) throws {
        guard let persistence else { return }
        do {
            let data = try JSONEncoder().encode(req)
            try persistence.save(key: Self.persistencePrefix + req.id, data: data)
        } catch {
            logger.error(.afterSales, "persist failed id=\(req.id) err=\(error)")
            throw AfterSalesError.persistenceFailed
        }
    }

    private func hydrate() {
        guard let persistence else { return }
        do {
            let entries = try persistence.loadAll(prefix: Self.persistencePrefix)
            let decoder = JSONDecoder()
            for entry in entries {
                if let r = try? decoder.decode(AfterSalesRequest.self, from: entry.data) {
                    requestStore[r.id] = r
                }
            }
        } catch {
            logger.error(.afterSales, "hydrate failed err=\(error)")
        }
    }

    /// Returns all requests. Intended for CSR/admin; use `requestsVisible(to:actingUser:)` for customer views.
    public func all() -> [AfterSalesRequest] {
        requestStore.values.sorted { $0.id < $1.id }
    }

    /// Attachment ids currently referenced as photo proof on any request.
    /// Used by `AttachmentService.runRetentionSweep` so photo evidence on an
    /// open ticket is never purged regardless of its age.
    public func referencedAttachmentIds() -> Set<String> {
        var ids: Set<String> = []
        for r in requestStore.values { for id in r.photoAttachmentIds { ids.insert(id) } }
        return ids
    }

    /// Returns requests visible to a specific user, enforcing object-level isolation.
    /// - Customers see only requests they themselves opened (`createdByUserId == userId`)
    ///   AND can only query their own id — `actingUser.id` must equal `userId`, otherwise
    ///   `AuthorizationError.forbidden` is thrown (prevents spoofed target-user queries).
    /// - CSR / admin see all requests and may query any `userId`.
    public func requestsVisible(to userId: String, actingUser: User) throws -> [AfterSalesRequest] {
        if RolePolicy.can(actingUser.role, .handleServiceTickets)
           || RolePolicy.can(actingUser.role, .configureSystem) {
            return all()
        }
        // Non-privileged roles may only query their own user id.
        guard actingUser.id == userId else {
            logger.warn(.afterSales, "requestsVisible forbidden actor=\(actingUser.id) target=\(userId)")
            throw AuthorizationError.forbidden(required: .handleServiceTickets)
        }
        return requestStore.values
            .filter { $0.createdByUserId == userId }
            .sorted { $0.id < $1.id }
    }

    /// Fool-proof convenience: returns requests visible to `actingUser` without
    /// accepting a caller-supplied target id. Call sites that don't need cross-user
    /// audit access should prefer this API — it eliminates spoofed-target misuse
    /// by construction.
    public func requestsVisible(actingUser: User) -> [AfterSalesRequest] {
        // safe: passing actingUser.id as the target cannot trigger the forbidden branch
        (try? requestsVisible(to: actingUser.id, actingUser: actingUser)) ?? []
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
                let prior = requestStore[r.id]
                r.status = .autoRejected
                r.resolvedAt = now
                requestStore[r.id] = r
                do {
                    try persist(r)
                } catch {
                    // Roll back the in-memory change if durability fails — keeps
                    // the store consistent so the next sweep retries rather than
                    // silently reporting the request as auto-rejected.
                    requestStore[r.id] = prior
                    logger.error(.afterSales, "runAutomation autoReject persist failed id=\(r.id)")
                    continue
                }
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
                let prior = requestStore[r.id]
                r.status = .autoApproved
                r.resolvedAt = now
                requestStore[r.id] = r
                do {
                    try persist(r)
                } catch {
                    requestStore[r.id] = prior
                    logger.error(.afterSales, "runAutomation autoApprove persist failed id=\(r.id)")
                    continue
                }
                notifier.post("afterSales.autoApproved:\(r.id)")
                changed.append(r.id)
            }
        }
        return changed
    }
}
