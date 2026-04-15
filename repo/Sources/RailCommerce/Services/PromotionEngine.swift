import Foundation

public enum DiscountKind: String, Codable, Sendable {
    case percentOff
    case amountOff
    case freeShipping
}

public struct Discount: Codable, Equatable, Sendable {
    public let code: String
    public let kind: DiscountKind
    /// For percent-off: 1..100. For amount-off: cents. Ignored for freeShipping.
    public let magnitude: Int
    /// Deterministic tie-breaker: lower priority applies first.
    public let priority: Int
    /// Optional SKU restriction. Empty = applies to whole cart.
    public let restrictedSkuIds: Set<String>

    public init(code: String, kind: DiscountKind, magnitude: Int,
                priority: Int, restrictedSkuIds: Set<String> = []) {
        self.code = code
        self.kind = kind
        self.magnitude = magnitude
        self.priority = priority
        self.restrictedSkuIds = restrictedSkuIds
    }
}

public struct LineExplanation: Equatable, Sendable {
    public let skuId: String
    public let originalCents: Int
    public let discountedCents: Int
    public let appliedCodes: [String]
}

public struct PromotionResult: Equatable, Sendable {
    public let acceptedCodes: [String]
    public let rejectedCodes: [String]
    public let subtotalCents: Int
    public let totalDiscountCents: Int
    public let finalCents: Int
    public let freeShipping: Bool
    public let lineExplanations: [LineExplanation]
    public let rejectionReasons: [String: String]
}

public enum PromotionEngine {
    public static let maxDiscounts = 3

    /// Deterministic application:
    ///  1. Sort discounts by (priority asc, code asc).
    ///  2. Reject any extra percent-off once one has been accepted.
    ///  3. Stop after three accepted discounts.
    ///  4. Apply per-line, record explanations.
    public static func apply(cart: Cart, discounts: [Discount]) -> PromotionResult {
        let sorted = discounts.sorted { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            return a.code < b.code
        }

        var accepted: [Discount] = []
        var rejected: [String] = []
        var reasons: [String: String] = [:]
        var hasPercent = false

        for d in sorted {
            if accepted.count >= maxDiscounts {
                rejected.append(d.code)
                reasons[d.code] = "max-discounts-exceeded"
                continue
            }
            if d.kind == .percentOff {
                if hasPercent {
                    rejected.append(d.code)
                    reasons[d.code] = "percent-off-stacking-blocked"
                    continue
                }
                if d.magnitude <= 0 || d.magnitude > 100 {
                    rejected.append(d.code)
                    reasons[d.code] = "percent-out-of-range"
                    continue
                }
                hasPercent = true
            }
            if d.kind == .amountOff && d.magnitude <= 0 {
                rejected.append(d.code)
                reasons[d.code] = "amount-non-positive"
                continue
            }
            accepted.append(d)
        }

        let subtotal = cart.subtotalCents
        var lineTotals: [String: Int] = [:]
        var lineApplied: [String: [String]] = [:]
        for line in cart.lines {
            lineTotals[line.sku.id] = line.subtotalCents
            lineApplied[line.sku.id] = []
        }

        var freeShipping = false

        for d in accepted {
            let targetIds: [String]
            if d.restrictedSkuIds.isEmpty {
                targetIds = cart.lines.map { $0.sku.id }
            } else {
                targetIds = cart.lines.map { $0.sku.id }.filter { d.restrictedSkuIds.contains($0) }
            }
            if targetIds.isEmpty {
                // Still record as applied so it counts toward the three-discount budget
                // but produces no line change. The prompt says pipeline enforces *at most*
                // three; we keep the count honest.
                continue
            }
            switch d.kind {
            case .percentOff:
                for id in targetIds {
                    let current = lineTotals[id]!
                    let reduced = current - (current * d.magnitude) / 100
                    lineTotals[id] = reduced
                    var applied = lineApplied[id]!
                    applied.append(d.code)
                    lineApplied[id] = applied
                }
            case .amountOff:
                // Spread amount-off across targeted lines proportional to current line total.
                let totalTargeted = targetIds.reduce(0) { $0 + lineTotals[$1]! }
                guard totalTargeted > 0 else { continue }
                var remainingCents = min(d.magnitude, totalTargeted)
                let lastId = targetIds.last!
                for id in targetIds {
                    let current = lineTotals[id]!
                    let share: Int
                    if id == lastId {
                        share = min(remainingCents, current)
                    } else {
                        share = (current * d.magnitude) / totalTargeted
                    }
                    let capped = min(share, current)
                    lineTotals[id] = current - capped
                    remainingCents -= capped
                    var applied = lineApplied[id]!
                    applied.append(d.code)
                    lineApplied[id] = applied
                }
            case .freeShipping:
                freeShipping = true
                // Record on every targeted line so the explanation reflects it.
                for id in targetIds {
                    var applied = lineApplied[id]!
                    applied.append(d.code)
                    lineApplied[id] = applied
                }
            }
        }

        let explanations = cart.lines.map { line -> LineExplanation in
            LineExplanation(
                skuId: line.sku.id,
                originalCents: line.subtotalCents,
                discountedCents: max(0, lineTotals[line.sku.id]!),
                appliedCodes: lineApplied[line.sku.id]!
            )
        }

        let finalCents = explanations.reduce(0) { $0 + $1.discountedCents }
        let totalDiscount = max(0, subtotal - finalCents)

        return PromotionResult(
            acceptedCodes: accepted.map { $0.code },
            rejectedCodes: rejected,
            subtotalCents: subtotal,
            totalDiscountCents: totalDiscount,
            finalCents: finalCents,
            freeShipping: freeShipping,
            lineExplanations: explanations,
            rejectionReasons: reasons
        )
    }
}
