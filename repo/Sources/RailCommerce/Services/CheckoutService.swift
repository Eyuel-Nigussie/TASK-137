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

    public init(orderId: String, userId: String, lines: [CartLine],
                promotion: PromotionResultSnapshot, address: USAddress,
                shipping: ShippingTemplate, invoiceNotes: String,
                totalCents: Int, createdAt: Date) {
        self.orderId = orderId; self.userId = userId; self.lines = lines
        self.promotion = promotion; self.address = address; self.shipping = shipping
        self.invoiceNotes = invoiceNotes; self.totalCents = totalCents; self.createdAt = createdAt
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
}

public final class CheckoutService {
    public static let duplicateLockoutSeconds: TimeInterval = 10

    private let clock: Clock
    private let keychain: SecureStore
    private var recent: [String: Date] = [:]         // orderId → submittedAt
    private var orderStore: [String: OrderSnapshot] = [:]

    private let _events = PublishSubject<CheckoutEvent>()
    /// Observable stream of checkout lifecycle events.
    public var events: Observable<CheckoutEvent> { _events.asObservable() }

    public init(clock: Clock, keychain: SecureStore) {
        self.clock = clock
        self.keychain = keychain
    }

    /// Submits an order, computes promotions, seals the tamper-proof hash in the Keychain,
    /// and enforces a 10-second duplicate-submission lockout.
    ///
    /// - Parameter actingUser: When supplied the caller must hold `.purchase` or
    ///   `.processTransaction`; otherwise `AuthorizationError.forbidden` is thrown.
    public func submit(
        orderId: String,
        userId: String,
        cart: Cart,
        discounts: [Discount],
        address: USAddress,
        shipping: ShippingTemplate?,
        invoiceNotes: String,
        actingUser: User? = nil
    ) throws -> OrderSnapshot {
        if let user = actingUser,
           !RolePolicy.can(user.role, .purchase),
           !RolePolicy.can(user.role, .processTransaction) {
            throw AuthorizationError.forbidden(required: .purchase)
        }
        guard !cart.isEmpty else { throw CheckoutError.emptyCart }
        guard let shipping else { throw CheckoutError.noShipping }
        do { try AddressValidator.validate(address) }
        catch let err as AddressValidationError { throw CheckoutError.addressInvalid(err) }

        let now = clock.now()
        if let last = recent[orderId], now.timeIntervalSince(last) < Self.duplicateLockoutSeconds {
            throw CheckoutError.duplicateSubmission
        }

        let promo = PromotionEngine.apply(cart: cart, discounts: discounts)
        let shippingCost = promo.freeShipping ? 0 : shipping.feeCents
        let totalCents = promo.finalCents + shippingCost

        let snapshot = OrderSnapshot(
            orderId: orderId, userId: userId, lines: cart.lines,
            promotion: PromotionResultSnapshot(from: promo),
            address: address, shipping: shipping, invoiceNotes: invoiceNotes,
            totalCents: totalCents, createdAt: now
        )

        let hash = OrderHasher.hash(snapshot: Self.canonicalFields(snapshot))
        try keychain.set(Data(hash.utf8), forKey: Self.keychainKey(for: orderId))
        if let memKeychain = keychain as? InMemoryKeychain { memKeychain.seal(Self.keychainKey(for: orderId)) }
        recent[orderId] = now
        orderStore[orderId] = snapshot
        _events.onNext(.orderSubmitted(orderId))
        return snapshot
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

    public func order(_ id: String) -> OrderSnapshot? { orderStore[id] }

    /// Returns all orders submitted by `userId`, sorted by order ID.
    public func orders(for userId: String) -> [OrderSnapshot] {
        orderStore.values.filter { $0.userId == userId }.sorted { $0.orderId < $1.orderId }
    }

    static func keychainKey(for orderId: String) -> String { "order.hash.\(orderId)" }

    /// Builds the canonical field map used for tamper-detection hashing.
    /// Covers the full monetary and address details — not just IDs.
    static func canonicalFields(_ s: OrderSnapshot) -> [String: String] {
        var fields: [String: String] = [
            "orderId":      s.orderId,
            "userId":       s.userId,
            "total":        String(s.totalCents),
            "createdAt":    String(Int(s.createdAt.timeIntervalSince1970)),
            "shippingId":   s.shipping.id,
            "shippingName": s.shipping.name,
            "shippingFee":  String(s.shipping.feeCents),
            "addrId":       s.address.id,
            "addrLine1":    s.address.line1,
            "addrCity":     s.address.city,
            "addrState":    s.address.state.rawValue,
            "addrZip":      s.address.zip,
            "invoiceNotes": s.invoiceNotes,
            "accepted":     s.promotion.acceptedCodes.joined(separator: ","),
            "freeShipping": s.promotion.freeShipping ? "1" : "0",
            "discountTotal": String(s.promotion.totalDiscountCents)
        ]
        let lineDesc = s.lines.map { "\($0.sku.id)x\($0.quantity)@\($0.sku.priceCents)" }
            .sorted().joined(separator: ";")
        fields["lines"] = lineDesc
        return fields
    }
}
