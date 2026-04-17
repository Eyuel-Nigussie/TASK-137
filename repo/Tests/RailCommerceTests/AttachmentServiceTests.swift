import XCTest
@testable import RailCommerce

final class AttachmentServiceTests: XCTestCase {
    func testSaveAndGet() throws {
        let clock = FakeClock()
        let svc = AttachmentService(clock: clock)
        let att = try svc.save(id: "a", data: Data(repeating: 0, count: 10), kind: .jpeg)
        XCTAssertEqual(att.sizeBytes, 10)
        XCTAssertEqual(try svc.get("a").id, "a")
        XCTAssertEqual(svc.all().count, 1)
    }

    func testTooLargeRejected() {
        let clock = FakeClock()
        let svc = AttachmentService(clock: clock)
        XCTAssertThrowsError(try svc.save(id: "big",
                                          data: Data(repeating: 0, count: AttachmentService.maxBytes + 1),
                                          kind: .jpeg)) { err in
            XCTAssertEqual(err as? AttachmentError, .tooLarge)
        }
    }

    func testMissingRaisesNotFound() {
        let svc = AttachmentService(clock: FakeClock())
        XCTAssertThrowsError(try svc.get("nope")) { err in
            XCTAssertEqual(err as? AttachmentError, .notFound)
        }
    }

    func testRetentionSweepRemoves30DayOld() throws {
        let clock = FakeClock()
        let svc = AttachmentService(clock: clock)
        _ = try svc.save(id: "old", data: Data([1]), kind: .png)
        clock.advance(by: 31 * 86_400)
        let removed = svc.runRetentionSweep()
        XCTAssertEqual(removed, ["old"])
        XCTAssertTrue(svc.all().isEmpty)
    }

    func testRetentionSweepKeepsRecent() throws {
        let clock = FakeClock()
        let svc = AttachmentService(clock: clock)
        _ = try svc.save(id: "new", data: Data([1]), kind: .png)
        clock.advance(by: 29 * 86_400)
        XCTAssertTrue(svc.runRetentionSweep().isEmpty)
    }

    func testAllSortedByIdWithMultipleAttachments() throws {
        let svc = AttachmentService(clock: FakeClock())
        _ = try svc.save(id: "b", data: Data([1]), kind: .png)
        _ = try svc.save(id: "a", data: Data([1]), kind: .png)
        XCTAssertEqual(svc.all().map { $0.id }, ["a", "b"])
    }

    func testStoredAttachmentCodable() throws {
        let a = StoredAttachment(id: "x", sandboxPath: "p", fileURL: nil,
                                 sizeBytes: 10, kind: .pdf,
                                 storedAt: Date(timeIntervalSince1970: 0), sha256: nil)
        let data = try JSONEncoder().encode(a)
        XCTAssertEqual(try JSONDecoder().decode(StoredAttachment.self, from: data), a)
    }
}
