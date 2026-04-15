import XCTest
@testable import RailCommerce

final class CartTests: XCTestCase {
    private func makeCatalog() -> Catalog {
        Catalog([
            SKU(id: "t1", kind: .ticket, title: "Ticket 1", priceCents: 1_000),
            SKU(id: "t2", kind: .ticket, title: "Ticket 2", priceCents: 2_000),
            SKU(id: "m1", kind: .merchandise, title: "Mug", priceCents: 500),
            SKU(id: "bundleA", kind: .bundle, title: "Combo", priceCents: 2_500,
                bundleChildren: ["t1", "t2"])
        ])
    }

    func testAddNewLine() throws {
        let cart = Cart(catalog: makeCatalog())
        let line = try cart.add(skuId: "t1", quantity: 2)
        XCTAssertEqual(line.quantity, 2)
        XCTAssertEqual(cart.subtotalCents, 2_000)
    }

    func testAddMergesWithExisting() throws {
        let cart = Cart(catalog: makeCatalog())
        try cart.add(skuId: "t1", quantity: 1)
        let merged = try cart.add(skuId: "t1", quantity: 2, notes: "vip")
        XCTAssertEqual(merged.quantity, 3)
        XCTAssertEqual(merged.notes, "vip")
    }

    func testAddRejectsUnknown() {
        let cart = Cart(catalog: makeCatalog())
        XCTAssertThrowsError(try cart.add(skuId: "nope", quantity: 1)) { error in
            XCTAssertEqual(error as? CartError, .unknownSku)
        }
    }

    func testAddRejectsNonPositiveQuantity() {
        let cart = Cart(catalog: makeCatalog())
        XCTAssertThrowsError(try cart.add(skuId: "t1", quantity: 0)) { error in
            XCTAssertEqual(error as? CartError, .nonPositiveQuantity)
        }
    }

    func testUpdateToZeroRemovesLine() throws {
        let cart = Cart(catalog: makeCatalog())
        try cart.add(skuId: "t1", quantity: 1)
        try cart.update(skuId: "t1", quantity: 0)
        XCTAssertTrue(cart.isEmpty)
    }

    func testUpdateNegative() {
        let cart = Cart(catalog: makeCatalog())
        XCTAssertThrowsError(try cart.update(skuId: "t1", quantity: -1)) { error in
            XCTAssertEqual(error as? CartError, .nonPositiveQuantity)
        }
    }

    func testUpdateChangesQuantity() throws {
        let cart = Cart(catalog: makeCatalog())
        try cart.add(skuId: "t1", quantity: 1)
        try cart.update(skuId: "t1", quantity: 5)
        XCTAssertEqual(cart.subtotalCents, 5_000)
    }

    func testUpdateMissingLine() {
        let cart = Cart(catalog: makeCatalog())
        XCTAssertThrowsError(try cart.update(skuId: "t1", quantity: 2)) { error in
            XCTAssertEqual(error as? CartError, .lineNotFound)
        }
    }

    func testRemoveAndClear() throws {
        let cart = Cart(catalog: makeCatalog())
        try cart.add(skuId: "t1", quantity: 1)
        try cart.add(skuId: "t2", quantity: 1)
        try cart.remove(skuId: "t1")
        XCTAssertEqual(cart.lines.count, 1)
        cart.clear()
        XCTAssertTrue(cart.isEmpty)
    }

    func testRemoveMissing() {
        let cart = Cart(catalog: makeCatalog())
        XCTAssertThrowsError(try cart.remove(skuId: "missing")) { error in
            XCTAssertEqual(error as? CartError, .lineNotFound)
        }
    }

    func testBundleSuggestionReportsMissingChildrenAndSavings() throws {
        let cart = Cart(catalog: makeCatalog())
        try cart.add(skuId: "t1", quantity: 1)
        let suggestions = cart.bundleSuggestions()
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.bundleId, "bundleA")
        XCTAssertEqual(suggestions.first?.missing, ["t2"])
        XCTAssertEqual(suggestions.first?.savingsCents, 500) // 3000-2500
    }

    func testBundleSuggestionNotShownIfNothingOwned() {
        let cart = Cart(catalog: makeCatalog())
        XCTAssertTrue(cart.bundleSuggestions().isEmpty)
    }

    func testBundleSuggestionNotShownIfAllOwned() throws {
        let cart = Cart(catalog: makeCatalog())
        try cart.add(skuId: "t1", quantity: 1)
        try cart.add(skuId: "t2", quantity: 1)
        XCTAssertTrue(cart.bundleSuggestions().isEmpty)
    }

    func testCartLineRespectsMinimumQuantity() {
        let line = CartLine(sku: SKU(id: "x", kind: .ticket, title: "T", priceCents: 100),
                            quantity: -4)
        XCTAssertEqual(line.quantity, 0)
    }

    func testMultipleBundleSuggestionsSorted() throws {
        let catalog = Catalog([
            SKU(id: "t1", kind: .ticket, title: "T1", priceCents: 1_000),
            SKU(id: "t2", kind: .ticket, title: "T2", priceCents: 2_000),
            SKU(id: "t3", kind: .ticket, title: "T3", priceCents: 3_000),
            SKU(id: "small", kind: .bundle, title: "Small", priceCents: 2_800,
                bundleChildren: ["t1", "t2"]),
            SKU(id: "big", kind: .bundle, title: "Big", priceCents: 4_000,
                bundleChildren: ["t1", "t3"])
        ])
        let cart = Cart(catalog: catalog)
        try cart.add(skuId: "t1", quantity: 1)
        let suggestions = cart.bundleSuggestions()
        XCTAssertEqual(suggestions.count, 2)
        // The bigger savings (big: 4000-4000=0? — 1000+3000-4000=0, small: 1000+2000-2800=200) sorted desc.
        XCTAssertEqual(suggestions.first?.bundleId, "small")
    }

    func testCartLineRoundTrip() throws {
        let line = CartLine(sku: SKU(id: "x", kind: .ticket, title: "T", priceCents: 100),
                            quantity: 1)
        let data = try JSONEncoder().encode(line)
        XCTAssertEqual(try JSONDecoder().decode(CartLine.self, from: data), line)
    }
}
