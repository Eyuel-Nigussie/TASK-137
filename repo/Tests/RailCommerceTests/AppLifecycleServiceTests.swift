import XCTest
@testable import RailCommerce

final class AppLifecycleServiceTests: XCTestCase {
    func testColdStartWithinBudget() {
        let svc = AppLifecycleService(clock: FakeClock())
        let begin = Date()
        let end = begin.addingTimeInterval(1.0)
        XCTAssertTrue(svc.markColdStart(begin: begin, end: end))
        XCTAssertEqual(svc.coldStartMillis, 1_000)
    }

    func testColdStartExceedsBudget() {
        let svc = AppLifecycleService(clock: FakeClock())
        let begin = Date()
        let end = begin.addingTimeInterval(2.0)
        XCTAssertFalse(svc.markColdStart(begin: begin, end: end))
    }

    func testMemoryWarningEvictsCacheAndDefersDecodes() {
        let svc = AppLifecycleService(clock: FakeClock())
        svc.cache(key: "a", data: Data([1]))
        svc.cache(key: "b", data: Data([2]))
        svc.scheduleDecode("img1")
        XCTAssertEqual(svc.cached("a"), Data([1]))
        XCTAssertEqual(svc.pendingDecodeKeys, ["img1"])
        svc.handleMemoryWarning()
        XCTAssertNil(svc.cached("a"))
        XCTAssertEqual(svc.cacheEvictions, 2)
        XCTAssertEqual(svc.deferredDecodes, 1)
        XCTAssertEqual(svc.memoryWarnings, 1)
        XCTAssertTrue(svc.pendingDecodeKeys.isEmpty)
    }
}
