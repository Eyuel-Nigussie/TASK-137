import XCTest
@testable import RailCommerce

final class ClockTests: XCTestCase {
    func testSystemClockReturnsRecentDate() {
        let clock = SystemClock()
        let before = Date()
        let now = clock.now()
        let after = Date()
        XCTAssertTrue(now >= before.addingTimeInterval(-0.5))
        XCTAssertTrue(now <= after.addingTimeInterval(0.5))
    }

    func testFakeClockAdvancesDeterministically() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = FakeClock(start)
        XCTAssertEqual(clock.now(), start)
        clock.advance(by: 60)
        XCTAssertEqual(clock.now(), start.addingTimeInterval(60))
    }

    func testFakeClockSet() {
        let clock = FakeClock()
        let target = Date(timeIntervalSince1970: 1)
        clock.set(target)
        XCTAssertEqual(clock.now(), target)
    }
}
