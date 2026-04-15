import XCTest
@testable import RailCommerce

final class BusinessTimeTests: XCTestCase {
    private func makeDate(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: iso)!
    }

    func testIsBusinessDay() {
        let monday = makeDate("2024-01-01T12:00:00Z")      // Monday
        let saturday = makeDate("2024-01-06T12:00:00Z")    // Saturday
        let sunday = makeDate("2024-01-07T12:00:00Z")      // Sunday
        XCTAssertTrue(BusinessTime.isBusinessDay(monday))
        XCTAssertFalse(BusinessTime.isBusinessDay(saturday))
        XCTAssertFalse(BusinessTime.isBusinessDay(sunday))
    }

    func testIsWithinBusinessHours() {
        let weekdayInHours = makeDate("2024-01-02T10:00:00Z")
        let weekdayOutOfHours = makeDate("2024-01-02T20:00:00Z")
        let weekend = makeDate("2024-01-06T10:00:00Z")
        XCTAssertTrue(BusinessTime.isWithinBusinessHours(weekdayInHours))
        XCTAssertFalse(BusinessTime.isWithinBusinessHours(weekdayOutOfHours))
        XCTAssertFalse(BusinessTime.isWithinBusinessHours(weekend))
    }

    func testAddBusinessHoursWithinOneDay() {
        let start = makeDate("2024-01-02T10:00:00Z")
        let due = BusinessTime.add(businessHours: 4, to: start)
        XCTAssertEqual(due, makeDate("2024-01-02T14:00:00Z"))
    }

    func testAddBusinessHoursOverNightRolloverToNextDay() {
        let start = makeDate("2024-01-02T16:00:00Z")
        let due = BusinessTime.add(businessHours: 4, to: start)
        // 1h Tue (16->17), 3h Wed (9->12)
        XCTAssertEqual(due, makeDate("2024-01-03T12:00:00Z"))
    }

    func testAddBusinessHoursStartingBeforeHours() {
        let start = makeDate("2024-01-02T04:00:00Z")
        let due = BusinessTime.add(businessHours: 2, to: start)
        XCTAssertEqual(due, makeDate("2024-01-02T11:00:00Z"))
    }

    func testAddBusinessHoursStartingAfterHoursOnFridayRollsToMonday() {
        let friday20 = makeDate("2024-01-05T20:00:00Z")
        let due = BusinessTime.add(businessHours: 1, to: friday20)
        XCTAssertEqual(due, makeDate("2024-01-08T10:00:00Z"))
    }

    func testAddBusinessHoursOnWeekend() {
        let saturday = makeDate("2024-01-06T10:00:00Z")
        let due = BusinessTime.add(businessHours: 1, to: saturday)
        XCTAssertEqual(due, makeDate("2024-01-08T10:00:00Z"))
    }

    func testAddBusinessDaysCrossesWeekend() {
        let thursday = makeDate("2024-01-04T10:00:00Z")
        let due = BusinessTime.add(businessDays: 3, to: thursday)
        // Thu + 3 business days = Tue
        XCTAssertEqual(due, makeDate("2024-01-09T10:00:00Z"))
    }

    func testAddZeroBusinessDays() {
        let start = makeDate("2024-01-02T10:00:00Z")
        XCTAssertEqual(BusinessTime.add(businessDays: 0, to: start), start)
    }
}
