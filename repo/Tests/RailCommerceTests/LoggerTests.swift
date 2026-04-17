import XCTest
@testable import RailCommerce

/// Tests for the structured logger abstraction and its PII redactor.
final class LoggerTests: XCTestCase {

    // MARK: - SilentLogger

    func testSilentLoggerAcceptsEveryLevelWithoutSideEffects() {
        let log = SilentLogger()
        log.debug(.auth, "x")
        log.info(.auth, "x")
        log.warn(.auth, "x")
        log.error(.auth, "x")
    }

    // MARK: - InMemoryLogger

    func testInMemoryLoggerCapturesAllLevels() {
        let log = InMemoryLogger(clock: FakeClock())
        log.debug(.auth, "d")
        log.info(.checkout, "i")
        log.warn(.inventory, "w")
        log.error(.messaging, "e")
        XCTAssertEqual(log.records.count, 4)
        XCTAssertEqual(log.records.map { $0.level }, [.debug, .info, .warn, .error])
    }

    func testInMemoryLoggerFiltersByCategory() {
        let log = InMemoryLogger(clock: FakeClock())
        log.info(.auth, "a")
        log.info(.checkout, "c")
        log.info(.auth, "b")
        XCTAssertEqual(log.records(in: .auth).count, 2)
        XCTAssertEqual(log.records(in: .checkout).count, 1)
    }

    func testInMemoryLoggerFiltersByLevel() {
        let log = InMemoryLogger(clock: FakeClock())
        log.warn(.auth, "w1")
        log.error(.auth, "e1")
        log.warn(.auth, "w2")
        XCTAssertEqual(log.records(at: .warn).count, 2)
        XCTAssertEqual(log.records(at: .error).count, 1)
    }

    func testInMemoryLoggerClearRemovesAllRecords() {
        let log = InMemoryLogger(clock: FakeClock())
        log.info(.auth, "x")
        log.clear()
        XCTAssertTrue(log.records.isEmpty)
    }

    func testInMemoryLoggerStampsTimestamps() {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_000))
        let log = InMemoryLogger(clock: clock)
        log.info(.auth, "first")
        clock.advance(by: 10)
        log.info(.auth, "second")
        XCTAssertEqual(log.records[0].at.timeIntervalSince1970, 1_000)
        XCTAssertEqual(log.records[1].at.timeIntervalSince1970, 1_010)
    }

    // MARK: - LogRedactor

    func testRedactorMasksEmail() {
        let out = LogRedactor.redact("contact alice@example.com today")
        XCTAssertTrue(out.contains("[email]"))
        XCTAssertFalse(out.contains("alice@example.com"))
    }

    func testRedactorMasksSSN() {
        let out = LogRedactor.redact("ssn 123-45-6789 goes here")
        XCTAssertTrue(out.contains("[ssn]"))
        XCTAssertFalse(out.contains("123-45-6789"))
    }

    func testRedactorMasksPaymentCard() {
        let out = LogRedactor.redact("card 4111 1111 1111 1111 in body")
        XCTAssertTrue(out.contains("[card]"))
    }

    func testRedactorMasksPhone() {
        let out = LogRedactor.redact("call 555-123-4567 now")
        XCTAssertTrue(out.contains("[phone]"))
        XCTAssertFalse(out.contains("555-123-4567"))
    }

    func testRedactorPreservesCleanMessages() {
        XCTAssertEqual(LogRedactor.redact("just a normal log"), "just a normal log")
    }

    func testRedactorAppliesAcrossMultipleCategories() {
        let out = LogRedactor.redact("alice@example.com or 555-123-4567 and ssn 999-11-2222")
        XCTAssertTrue(out.contains("[email]"))
        XCTAssertTrue(out.contains("[phone]"))
        XCTAssertTrue(out.contains("[ssn]"))
    }

    func testInMemoryLoggerAppliesRedactorAutomatically() {
        let log = InMemoryLogger(clock: FakeClock())
        log.info(.messaging, "contact alice@example.com")
        XCTAssertEqual(log.records.first?.message, "contact [email]")
    }

    // MARK: - LogRecord

    func testLogRecordEquatable() {
        let at = Date(timeIntervalSince1970: 0)
        let a = LogRecord(level: .info, category: .auth, message: "m", at: at)
        let b = LogRecord(level: .info, category: .auth, message: "m", at: at)
        XCTAssertEqual(a, b)
    }

    func testLogCategoryAllCasesCoverEveryService() {
        // Ensures the enum closes over the service taxonomy we rely on.
        let expected: Set<LogCategory> = [
            .auth, .checkout, .inventory, .afterSales,
            .messaging, .content, .persistence, .transport, .lifecycle
        ]
        XCTAssertEqual(Set(LogCategory.allCases), expected)
    }
}
