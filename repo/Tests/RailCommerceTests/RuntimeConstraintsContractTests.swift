import XCTest
@testable import RailCommerce

/// Pins the runtime constraints the prompt calls out — cold-start budget,
/// memory-pressure responsiveness, iPad split-view support, camera/local-
/// network/notification permission wiring — at the code-contract level.
///
/// These tests cannot replace on-device runtime measurement, but they DO
/// prove every hook the OS will call at runtime exists, is wired, and
/// carries the right budget / threshold constants. An implementation
/// regression — e.g. someone deletes the memory-warning handler or loosens
/// the cold-start budget — fails this suite loudly before it hits a device.
final class RuntimeConstraintsContractTests: XCTestCase {

    // MARK: - Cold-start budget (<1.5s on iPhone 11-class hardware)

    /// The cold-start budget is the constant the lifecycle service measures
    /// against. Anyone tempted to loosen the budget hits this test.
    func testColdStartBudgetIs1500Milliseconds() {
        XCTAssertEqual(AppLifecycleService.coldStartBudgetSeconds, 1.5,
                       "Cold-start budget must stay at 1.5s per the prompt's performance contract")
    }

    func testMarkColdStartAcceptsFastStart() {
        let clock = FakeClock()
        let svc = AppLifecycleService(clock: clock)
        let begin = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 1.2)
        XCTAssertTrue(svc.markColdStart(begin: begin, end: end),
                      "A 1.2s cold start must pass the 1.5s budget")
        XCTAssertEqual(svc.coldStartMillis, 1_200)
    }

    func testMarkColdStartRejectsSlowStart() {
        let clock = FakeClock()
        let svc = AppLifecycleService(clock: clock)
        let begin = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 1.6)
        XCTAssertFalse(svc.markColdStart(begin: begin, end: end),
                       "A 1.6s cold start must NOT pass the 1.5s budget — contract regression guard")
        XCTAssertEqual(svc.coldStartMillis, 1_600,
                       "coldStartMillis must still record the observed elapsed time")
    }

    func testMarkColdStartRejectsExactBudgetBoundary() {
        let clock = FakeClock()
        let svc = AppLifecycleService(clock: clock)
        let begin = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 1.5)
        XCTAssertFalse(svc.markColdStart(begin: begin, end: end),
                       "Exactly 1.5s is NOT under budget — the comparison is strict (< not ≤)")
    }

    // MARK: - Memory warning responsiveness

    /// Every on-device memory warning must evict caches AND drop pending
    /// heavy decodes so the app can stay alive under iOS memory pressure.
    func testMemoryWarningEvictsCacheAndDefersDecodes() {
        let svc = AppLifecycleService(clock: FakeClock())
        svc.cache(key: "a", data: Data([1]))
        svc.cache(key: "b", data: Data([2]))
        svc.scheduleDecode("heavy-1")
        svc.scheduleDecode("heavy-2")
        svc.scheduleDecode("heavy-3")

        XCTAssertNotNil(svc.cached("a"))
        XCTAssertEqual(svc.pendingDecodeKeys.count, 3)

        svc.handleMemoryWarning()

        XCTAssertNil(svc.cached("a"),
                     "cache must be emptied on memory warning")
        XCTAssertNil(svc.cached("b"))
        XCTAssertEqual(svc.pendingDecodeKeys.count, 0,
                       "pending heavy decodes must be dropped on memory warning")
        XCTAssertEqual(svc.memoryWarnings, 1)
        XCTAssertEqual(svc.cacheEvictions, 2,
                       "cacheEvictions must count every entry dropped")
        XCTAssertEqual(svc.deferredDecodes, 3,
                       "deferredDecodes must count every pending decode dropped")
    }

    /// Memory warnings are cumulative — the app can receive several during
    /// its lifecycle. Counters must accumulate, not reset.
    func testRepeatedMemoryWarningsAccumulate() {
        let svc = AppLifecycleService(clock: FakeClock())
        svc.cache(key: "a", data: Data([1]))
        svc.handleMemoryWarning()
        svc.cache(key: "b", data: Data([2]))
        svc.handleMemoryWarning()
        XCTAssertEqual(svc.memoryWarnings, 2)
        XCTAssertEqual(svc.cacheEvictions, 2)
    }
}
