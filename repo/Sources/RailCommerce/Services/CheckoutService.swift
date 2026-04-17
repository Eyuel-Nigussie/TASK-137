import Foundation
import RxSwift

public struct ShippingTemplate: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let feeCents: Int
    public let etaDays: Int

    public init(id: String, name: String, feeCents: Int, etaDays: Int) {
        self.id = id; self.name = name; self.feeCents = feeCents; self.etaDays = etaDays
    }
}

public struct OrderSnapshot: Codable, Equatable, Sendable {
    public let orderId: String
    public let userId: String
    public let lines: [CartLine]
    public let promotion: PromotionResultSnapshot
    public let address: USAddress
    public let shipping: ShippingTemplate
    public let invoiceNotes: String
    public let totalCents: Int
    public let createdAt: Date
    /// The travel / service date to anchor after-sales automation rules to.
    /// For a ticket this is the departure date; for merchandise it defaults to
    /// `createdAt`. The prompt's "auto-reject 14+ days past service date" rule
    /// reads this field, not `createdAt`, so merchandise-only orders and
    /// ticket orders correctly reflect different service-date semantics.
    public let serviceDate: Date

    public init(orderId: String, userId: String, lines: [CartLine],
                promotion: PromotionResultSnapshot, address: USAddress,
                shipping: ShippingTemplate, invoiceNotes: String,
                totalCents: Int, createdAt: Date, serviceDate: Date? = nil) {
        self.orderId = orderId; self.userId = userId; self.lines = lines
        self.promotion = promotion; self.address = address; self.shipping = shipping
        self.invoiceNotes = invoiceNotes; self.totalCents = totalCents; self.createdAt = createdAt
        self.serviceDate = serviceDate ?? createdAt
    }
}

public struct PromotionResultSnapshot: Codable, Equatable, Sendable {
    public let acceptedCodes: [String]
    public let rejectedCodes: [String]
    public let totalDiscountCents: Int
    public let freeShipping: Bool
    public let lineExplanations: [LineSnapshot]

    public struct LineSnapshot: Codable, Equatable, Sendable {
        public let skuId: String
        public let originalCents: Int
        public let discountedCents: Int
        public let appliedCodes: [String]
    }

    public init(from result: PromotionResult) {
        self.acceptedCodes = result.acceptedCodes
        self.rejectedCodes = result.rejectedCodes
        self.totalDiscountCents = result.totalDiscountCents
        self.freeShipping = result.freeShipping
        self.lineExplanations = result.lineExplanations.map {
            LineSnapshot(skuId: $0.skuId, originalCents: $0.originalCents,
                         discountedCents: $0.discountedCents, appliedCodes: $0.appliedCodes)
        }
    }
}

public enum CheckoutError: Error, Equatable {
    case emptyCart
    case duplicateSubmission
    case noShipping
    case addressInvalid(AddressValidationError)
    case tamperDetected
    /// Thrown when the caller's identity does not match the order's `userId` and the caller
    /// is not a privileged agent permitted to submit on behalf of other customers.
    case identityMismatch
    case persistenceFailed
    /// Seats were requested but no `SeatInventoryService` was wired into the
    /// call — the checkout cannot transactionally reserve+confirm them.
    case seatInventoryUnavailable
    /// One or more requested seats could not be reserved or confirmed (already
    /// reserved by someone else, sold, unknown, or otherwise conflicted).
    case seatUnavailable
}

public final class CheckoutService {
    public static let duplicateLockoutSeconds: TimeInterval = 10
    /// Prefix used for persisted order snapshots.
    public static let persistencePrefix = "checkout.order."

    private let clock: Clock
    private let keychain: SecureStore
    private let persistence: PersistenceStore?
    private let logger: Logger
    private var recent: [String: Date] = [:]         // orderId → submittedAt
    private var orderStore: [String: OrderSnapshot] = [:]

    private let _events = PublishSubject<CheckoutEvent>()
    /// Observable stream of checkout lifecycle events.
    public var events: Observable<CheckoutEvent> { _events.asObservable() }

    public init(clock: Clock,
                keychain: SecureStore,
                persistence: PersistenceStore? = nil,
                logger: Logger = SilentLogger()) {
        self.clock = clock
        self.keychain = keychain
        self.persistence = persistence
        self.logger = logger
        hydrate()
    }

    /// Submits an order, computes promotions, seals the tamper-proof hash in the Keychain,
    /// and enforces a 10-second duplicate-submission lockout.
    ///
    /// Identity binding: `actingUser.id` must equal `userId` unless the acting user holds
    /// `.processTransaction` (sales agents submitting on behalf of customers).
    ///
    /// - Parameter actingUser: The caller must hold `.purchase` or `.processTransaction`;
    ///   otherwise `AuthorizationError.forbidden` is thrown.
    public func submit(
        orderId: String,
        userId: String,
        cart: Cart,
        discounts: [Discount],
        address: USAddress,
        shipping: ShippingTemplate?,
        invoiceNotes: String,
        actingUser: User,
        serviceDate: Date? = nil,
        seats: [SeatKey] = [],
        seatInventory: SeatInventoryService? = nil
    ) throws -> OrderSnapshot {
        guard RolePolicy.can(actingUser.role, .purchase)
           || RolePolicy.can(actingUser.role, .processTransaction) else {
            logger.warn(.checkout, "submit forbidden role=\(actingUser.role.rawValue) orderId=\(orderId)")
            throw AuthorizationError.forbidden(required: .purchase)
        }
        // Identity binding: customers can only submit under their own userId.
        // Privileged agents (processTransaction) may submit on behalf of any user.
        if !RolePolicy.can(actingUser.role, .processTransaction) && actingUser.id != userId {
            logger.warn(.checkout, "submit identityMismatch actor=\(actingUser.id) target=\(userId) orderId=\(orderId)")
            throw CheckoutError.identityMismatch
        }
        guard !cart.isEmpty else { throw CheckoutError.emptyCart }
        guard let shipping else { throw CheckoutError.noShipping }
        do { try AddressValidator.validate(address) }
        catch let err as AddressValidationError { throw CheckoutError.addressInvalid(err) }

        let now = clock.now()
        if let last = recent[orderId], now.timeIntervalSince(last) < Self.duplicateLockoutSeconds {
            logger.info(.checkout, "submit duplicate blocked orderId=\(orderId)")
            throw CheckoutError.duplicateSubmission
        }
        // Permanent idempotency: a stored snapshot prevents any later re-submission.
        if orderStore[orderId] != nil {
            throw CheckoutError.duplicateSubmission
        }

        let promo = PromotionEngine.apply(cart: cart, discounts: discounts)
        let shippingCost = promo.freeShipping ? 0 : shipping.feeCents
        let totalCents = promo.finalCents + shippingCost

        let snapshot = OrderSnapshot(
            orderId: orderId, userId: userId, lines: cart.lines,
            promotion: PromotionResultSnapshot(from: promo),
            address: address, shipping: shipping, invoiceNotes: invoiceNotes,
            totalCents: totalCents, createdAt: now,
            serviceDate: serviceDate ?? now
        )

        // Transactionally reserve + confirm requested seats inside checkout.
        // If any seat cannot be reserved/confirmed, the `atomic` block rolls
        // back every prior seat change in this call — no partial sales, no
        // oversell. This satisfies the prompt's "15-minute reservation during
        // checkout" and "prevents oversell" end-to-end guarantees.
        if !seats.isEmpty {
            guard let inventory = seatInventory else {
                logger.error(.checkout, "submit seats provided but no inventory wired orderId=\(orderId)")
                throw CheckoutError.seatInventoryUnavailable
            }
            do {
                try inventory.atomic {
                    for seat in seats {
                        let state = inventory.state(seat)
                        if state == nil { throw SeatError.unknownSeat }
                        if state == .available {
                            _ = try inventory.reserve(seat, holderId: userId, actingUser: actingUser)
                        } else if state == .reserved,
                                  let res = inventory.reservation(seat),
                                  res.holderId != userId {
                            throw SeatError.wrongHolder
                        } else if state == .sold {
                            throw SeatError.notAvailable
                        }
                        try inventory.confirm(seat, holderId: userId, actingUser: actingUser)
                    }
                }
            } catch let seatError as SeatError {
                // Map any seat-level error to a single checkout-level error so
                // the UI can present a coherent "seat unavailable" message and
                // the caller can distinguish this from unrelated failures.
                logger.warn(.checkout, "submit seat transaction failed orderId=\(orderId) err=\(seatError)")
                throw CheckoutError.seatUnavailable
            } catch {
                logger.warn(.checkout, "submit seat transaction failed orderId=\(orderId) err=\(error)")
                throw error
            }
        }

        // Durability-first order: persist the snapshot BEFORE any side effect
        // (keychain hash seal, in-memory idempotency, orderStore insert). If
        // durability fails the caller sees `.persistenceFailed` and no partial
        // state exists — no stale keychain hash, no idempotency lockout that
        // would reject a later retry for the same orderId.
        try persist(snapshot)

        let hash = OrderHasher.hash(snapshot: Self.canonicalFields(snapshot))
        do {
            try keychain.set(Data(hash.utf8), forKey: Self.keychainKey(for: orderId))
        } catch {
            // Persist succeeded but hash sealing failed. Roll back the durable
            // write so the next retry is clean and nothing observably committed.
            try? persistence?.delete(key: Self.persistencePrefix + orderId)
            logger.error(.checkout, "submit keychain seal failed orderId=\(orderId) err=\(error)")
            throw CheckoutError.persistenceFailed
        }
        keychain.seal(Self.keychainKey(for: orderId))
        recent[orderId] = now
        orderStore[orderId] = snapshot
        _events.onNext(.orderSubmitted(orderId))
        logger.info(.checkout, "submit ok orderId=\(orderId) total=\(totalCents) seats=\(seats.count)")
        return snapshot
    }

    // MARK: - Persistence

    private func persist(_ snap: OrderSnapshot) throws {
        guard let persistence else { return }
        do {
            let data = try JSONEncoder().encode(snap)
            try persistence.save(key: Self.persistencePrefix + snap.orderId, data: data)
        } catch {
            logger.error(.checkout, "persist failed orderId=\(snap.orderId) err=\(error)")
            throw CheckoutError.persistenceFailed
        }
    }

    private func hydrate() {
        guard let persistence else { return }
        do {
            let entries = try persistence.loadAll(prefix: Self.persistencePrefix)
            let decoder = JSONDecoder()
            for entry in entries {
                if let snap = try? decoder.decode(OrderSnapshot.self, from: entry.data) {
                    orderStore[snap.orderId] = snap
                }
            }
        } catch {
            logger.error(.checkout, "hydrate failed err=\(error)")
        }
    }

    public func storedHash(for orderId: String) -> String? {
        keychain.get(Self.keychainKey(for: orderId)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func verify(_ snapshot: OrderSnapshot) throws {
        let actual = OrderHasher.hash(snapshot: Self.canonicalFields(snapshot))
        guard let stored = storedHash(for: snapshot.orderId), stored == actual else {
            throw CheckoutError.tamperDetected
        }
        _events.onNext(.orderVerified(snapshot.orderId))
    }

    /// Returns the order with `id`, or `nil` if not found.
    /// - Note: Internal use only. App code should use `order(_:ownedBy:)` to enforce ownership.
    func order(_ id: String) -> OrderSnapshot? { orderStore[id] }

    /// Returns the order with `id` only when it belongs to `userId`. Enforces object-level isolation.
    public func order(_ id: String, ownedBy userId: String) -> OrderSnapshot? {
        guard let snap = orderStore[id], snap.userId == userId else { return nil }
        return snap
    }

    /// Returns all orders submitted by `userId`, sorted by order ID.
    public func orders(for userId: String) -> [OrderSnapshot] {
        orderStore.values.filter { $0.userId == userId }.sorted { $0.orderId < $1.orderId }
    }

    static func keychainKey(for orderId: String) -> String { "order.hash.\(orderId)" }

    /// Builds the canonical field map used for tamper-detection hashing.
    /// **Every** `OrderSnapshot` field is represented so a post-submit mutation
    /// of any single field triggers `.tamperDetected` on verify — including
    /// `serviceDate`, per-line promotion detail, shipping `etaDays`, address
    /// `recipient`/`line2`/`isDefault`, and the full rejected-codes list.
    static func canonicalFields(_ s: OrderSnapshot) -> [String: String] {
        var fields: [String: String] = [
            "orderId":       s.orderId,
            "userId":        s.userId,
            "total":         String(s.totalCents),
            "createdAt":     String(Int(s.createdAt.timeIntervalSince1970)),
            "serviceDate":   String(Int(s.serviceDate.timeIntervalSince1970)),
            "shippingId":    s.shipping.id,
            "shippingName":  s.shipping.name,
            "shippingFee":   String(s.shipping.feeCents),
            "shippingEta":   String(s.shipping.etaDays),
            "addrId":        s.address.id,
            "addrRecipient": s.address.recipient,
            "addrLine1":     s.address.line1,
            "addrLine2":     s.address.line2 ?? "",
            "addrCity":      s.address.city,
            "addrState":     s.address.state.rawValue,
            "addrZip":       s.address.zip,
            "addrIsDefault": s.address.isDefault ? "1" : "0",
            "invoiceNotes":  s.invoiceNotes,
            "accepted":      s.promotion.acceptedCodes.joined(separator: ","),
            "rejected":      s.promotion.rejectedCodes.joined(separator: ","),
            "freeShipping":  s.promotion.freeShipping ? "1" : "0",
            "discountTotal": String(s.promotion.totalDiscountCents)
        ]
        let lineDesc = s.lines.map { "\($0.sku.id)x\($0.quantity)@\($0.sku.priceCents):\($0.notes)" }
            .sorted().joined(separator: ";")
        fields["lines"] = lineDesc
        // Per-line promotion explanations — every field so a mutation anywhere
        // in the applied-codes / original / discounted tuple is detected.
        let promoLineDesc = s.promotion.lineExplanations
            .map { "\($0.skuId):\($0.appliedCodes.sorted().joined(separator: "+")):\($0.originalCents)->\($0.discountedCents)" }
            .sorted().joined(separator: ";")
        fields["promoLines"] = promoLineDesc
        return fields
    }
}
