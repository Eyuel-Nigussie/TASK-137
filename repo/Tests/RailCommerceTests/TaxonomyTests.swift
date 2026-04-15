import XCTest
@testable import RailCommerce

final class TaxonomyTests: XCTestCase {
    func testFullMatch() {
        let tag = TaxonomyTag(region: .northeast, theme: .scenic, riderType: .tourist)
        XCTAssertTrue(tag.matches(TaxonomyTag(region: .northeast)))
        XCTAssertTrue(tag.matches(TaxonomyTag(theme: .scenic)))
        XCTAssertTrue(tag.matches(TaxonomyTag(riderType: .tourist)))
        XCTAssertTrue(tag.matches(TaxonomyTag()))
    }

    func testMismatchByRegion() {
        let tag = TaxonomyTag(region: .west)
        XCTAssertFalse(tag.matches(TaxonomyTag(region: .south)))
    }

    func testMismatchByTheme() {
        let tag = TaxonomyTag(theme: .business)
        XCTAssertFalse(tag.matches(TaxonomyTag(theme: .scenic)))
    }

    func testMismatchByRiderType() {
        let tag = TaxonomyTag(riderType: .commuter)
        XCTAssertFalse(tag.matches(TaxonomyTag(riderType: .senior)))
    }

    func testEnumRoundTrip() throws {
        for region in Region.allCases {
            let data = try JSONEncoder().encode(region)
            XCTAssertEqual(try JSONDecoder().decode(Region.self, from: data), region)
        }
        for theme in Theme.allCases {
            let data = try JSONEncoder().encode(theme)
            XCTAssertEqual(try JSONDecoder().decode(Theme.self, from: data), theme)
        }
        for rider in RiderType.allCases {
            let data = try JSONEncoder().encode(rider)
            XCTAssertEqual(try JSONDecoder().decode(RiderType.self, from: data), rider)
        }
    }
}
