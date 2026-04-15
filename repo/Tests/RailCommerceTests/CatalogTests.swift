import XCTest
@testable import RailCommerce

final class CatalogTests: XCTestCase {
    func testUpsertAndGet() {
        let sku = SKU(id: "s1", kind: .ticket, title: "NE Express", priceCents: 100)
        let catalog = Catalog()
        catalog.upsert(sku)
        XCTAssertEqual(catalog.get("s1"), sku)
        XCTAssertEqual(catalog.all.count, 1)
    }

    func testFilterByTag() {
        let c = Catalog([
            SKU(id: "a", kind: .ticket, title: "A", priceCents: 100,
                tag: TaxonomyTag(region: .northeast)),
            SKU(id: "b", kind: .ticket, title: "B", priceCents: 100,
                tag: TaxonomyTag(region: .west))
        ])
        let filtered = c.filter(TaxonomyTag(region: .northeast))
        XCTAssertEqual(filtered.map { $0.id }, ["a"])
    }

    func testRemove() {
        let c = Catalog([SKU(id: "a", kind: .merchandise, title: "Mug", priceCents: 500)])
        c.remove(id: "a")
        XCTAssertNil(c.get("a"))
        XCTAssertTrue(c.all.isEmpty)
    }

    func testSKURoundTrip() throws {
        let sku = SKU(id: "bundle1", kind: .bundle, title: "Weekend",
                      priceCents: 4_000, tag: TaxonomyTag(), bundleChildren: ["a", "b"])
        let data = try JSONEncoder().encode(sku)
        XCTAssertEqual(try JSONDecoder().decode(SKU.self, from: data), sku)
    }

    func testSkuKindRoundTrip() throws {
        for kind in [SkuKind.ticket, .merchandise, .bundle] {
            let data = try JSONEncoder().encode(kind)
            XCTAssertEqual(try JSONDecoder().decode(SkuKind.self, from: data), kind)
        }
    }
}
