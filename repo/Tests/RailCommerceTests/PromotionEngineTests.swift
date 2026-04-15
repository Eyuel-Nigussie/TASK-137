import XCTest
@testable import RailCommerce

final class PromotionEngineTests: XCTestCase {
    private func makeCart() -> Cart {
        let catalog = Catalog([
            SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 1_000),
            SKU(id: "t2", kind: .ticket, title: "T2", priceCents: 2_000)
        ])
        let cart = Cart(catalog: catalog)
        try! cart.add(skuId: "t1", quantity: 1)
        try! cart.add(skuId: "t2", quantity: 1)
        return cart
    }

    func testSinglePercentOff() {
        let cart = makeCart()
        let discount = Discount(code: "PCT10", kind: .percentOff, magnitude: 10, priority: 1)
        let result = PromotionEngine.apply(cart: cart, discounts: [discount])
        XCTAssertEqual(result.subtotalCents, 3_000)
        XCTAssertEqual(result.finalCents, 2_700)
        XCTAssertEqual(result.totalDiscountCents, 300)
        XCTAssertEqual(result.acceptedCodes, ["PCT10"])
        XCTAssertTrue(result.rejectedCodes.isEmpty)
    }

    func testTwoPercentOffCoupons_OneRejected() {
        let cart = makeCart()
        let discounts = [
            Discount(code: "PCT10", kind: .percentOff, magnitude: 10, priority: 1),
            Discount(code: "PCT20", kind: .percentOff, magnitude: 20, priority: 2)
        ]
        let result = PromotionEngine.apply(cart: cart, discounts: discounts)
        XCTAssertEqual(result.acceptedCodes, ["PCT10"])
        XCTAssertEqual(result.rejectedCodes, ["PCT20"])
        XCTAssertEqual(result.rejectionReasons["PCT20"], "percent-off-stacking-blocked")
    }

    func testMaxThreeDiscountsEnforced() {
        let cart = makeCart()
        let discounts = [
            Discount(code: "A", kind: .amountOff, magnitude: 10, priority: 1),
            Discount(code: "B", kind: .amountOff, magnitude: 20, priority: 2),
            Discount(code: "C", kind: .amountOff, magnitude: 30, priority: 3),
            Discount(code: "D", kind: .amountOff, magnitude: 40, priority: 4)
        ]
        let result = PromotionEngine.apply(cart: cart, discounts: discounts)
        XCTAssertEqual(result.acceptedCodes.count, 3)
        XCTAssertEqual(result.rejectedCodes, ["D"])
        XCTAssertEqual(result.rejectionReasons["D"], "max-discounts-exceeded")
    }

    func testPercentOutOfRangeRejected() {
        let cart = makeCart()
        let discounts = [
            Discount(code: "BAD", kind: .percentOff, magnitude: 150, priority: 1),
            Discount(code: "ZERO", kind: .percentOff, magnitude: 0, priority: 2)
        ]
        let result = PromotionEngine.apply(cart: cart, discounts: discounts)
        XCTAssertEqual(result.rejectionReasons["BAD"], "percent-out-of-range")
        XCTAssertEqual(result.rejectionReasons["ZERO"], "percent-out-of-range")
    }

    func testAmountOffProportionalSpread() {
        let cart = makeCart()
        let discount = Discount(code: "AMT", kind: .amountOff, magnitude: 600, priority: 1)
        let result = PromotionEngine.apply(cart: cart, discounts: [discount])
        // 600 / 3000 total. t1 ~ 200, t2 ~ 400
        XCTAssertEqual(result.finalCents, 2_400)
    }

    func testAmountOffCappedAtCartTotal() {
        let cart = makeCart()
        let discount = Discount(code: "AMT", kind: .amountOff, magnitude: 10_000, priority: 1)
        let result = PromotionEngine.apply(cart: cart, discounts: [discount])
        XCTAssertEqual(result.finalCents, 0)
    }

    func testAmountNonPositiveRejected() {
        let cart = makeCart()
        let discount = Discount(code: "BAD", kind: .amountOff, magnitude: 0, priority: 1)
        let result = PromotionEngine.apply(cart: cart, discounts: [discount])
        XCTAssertEqual(result.rejectionReasons["BAD"], "amount-non-positive")
    }

    func testFreeShippingMarkedAndEmitsLineExplanation() {
        let cart = makeCart()
        let discount = Discount(code: "SHIP", kind: .freeShipping, magnitude: 0, priority: 1)
        let result = PromotionEngine.apply(cart: cart, discounts: [discount])
        XCTAssertTrue(result.freeShipping)
        XCTAssertTrue(result.lineExplanations.allSatisfy { $0.appliedCodes.contains("SHIP") })
    }

    func testRestrictedDiscountOnlyAffectsTarget() {
        let cart = makeCart()
        let discount = Discount(code: "T1_ONLY", kind: .percentOff,
                                magnitude: 50, priority: 1,
                                restrictedSkuIds: ["t1"])
        let result = PromotionEngine.apply(cart: cart, discounts: [discount])
        // t1 from 1000 -> 500, t2 unchanged
        XCTAssertEqual(result.finalCents, 500 + 2_000)
        XCTAssertTrue(result.lineExplanations.first { $0.skuId == "t2" }!
            .appliedCodes.isEmpty)
    }

    func testRestrictedDiscountNoMatchingLines() {
        let cart = makeCart()
        let discount = Discount(code: "NONE", kind: .percentOff,
                                magnitude: 10, priority: 1,
                                restrictedSkuIds: ["does-not-exist"])
        let result = PromotionEngine.apply(cart: cart, discounts: [discount])
        XCTAssertEqual(result.finalCents, 3_000) // no change
        XCTAssertEqual(result.acceptedCodes, ["NONE"])
    }

    func testDeterministicOrderingByPriorityThenCode() {
        let cart = makeCart()
        let discounts = [
            Discount(code: "B", kind: .amountOff, magnitude: 100, priority: 2),
            Discount(code: "A", kind: .amountOff, magnitude: 100, priority: 2),
            Discount(code: "C", kind: .amountOff, magnitude: 100, priority: 1)
        ]
        let result = PromotionEngine.apply(cart: cart, discounts: discounts)
        XCTAssertEqual(result.acceptedCodes, ["C", "A", "B"])
    }

    func testDiscountKindEncoding() throws {
        for kind in [DiscountKind.percentOff, .amountOff, .freeShipping] {
            let data = try JSONEncoder().encode(kind)
            XCTAssertEqual(try JSONDecoder().decode(DiscountKind.self, from: data), kind)
        }
    }

    func testEmptyCartProducesEmptyResult() {
        let catalog = Catalog([SKU(id: "x", kind: .ticket, title: "x", priceCents: 1)])
        let cart = Cart(catalog: catalog)
        let discount = Discount(code: "X", kind: .percentOff, magnitude: 50, priority: 1)
        let result = PromotionEngine.apply(cart: cart, discounts: [discount])
        XCTAssertEqual(result.finalCents, 0)
        XCTAssertEqual(result.subtotalCents, 0)
    }

    func testAmountOffZeroRemainingHandled() {
        // Make a cart whose line totals become zero before the amount-off applies.
        let catalog = Catalog([SKU(id: "a", kind: .ticket, title: "A", priceCents: 100)])
        let cart = Cart(catalog: catalog)
        try! cart.add(skuId: "a", quantity: 1)
        let zero = Discount(code: "Z", kind: .percentOff, magnitude: 100, priority: 1)
        let amt = Discount(code: "A", kind: .amountOff, magnitude: 50, priority: 2)
        let result = PromotionEngine.apply(cart: cart, discounts: [zero, amt])
        XCTAssertEqual(result.finalCents, 0)
    }
}
