import XCTest
@testable import RailCommerce

/// Tests for real file-backed attachment storage including SHA-256 tamper detection.
final class AttachmentFileIOTests: XCTestCase {

    func testSaveWritesBytesToFileStore() throws {
        let fileStore = InMemoryFileStore()
        let svc = AttachmentService(clock: FakeClock(), fileStore: fileStore)
        let data = Data([1, 2, 3, 4, 5])
        let att = try svc.save(id: "a1", data: data, kind: .jpeg)
        XCTAssertNotNil(att.fileURL)
        XCTAssertNotNil(att.sha256)
        XCTAssertTrue(fileStore.exists(at: att.fileURL!))
    }

    func testReadDataReturnsOriginalBytes() throws {
        let fileStore = InMemoryFileStore()
        let svc = AttachmentService(clock: FakeClock(), fileStore: fileStore)
        let original = Data([10, 20, 30])
        _ = try svc.save(id: "a1", data: original, kind: .png)
        let read = try svc.readData("a1")
        XCTAssertEqual(read, original)
    }

    func testReadDataMissingThrows() {
        let svc = AttachmentService(clock: FakeClock())
        XCTAssertThrowsError(try svc.readData("ghost")) { err in
            XCTAssertEqual(err as? AttachmentError, .notFound)
        }
    }

    func testGetVerifiesHashAndDetectsTamper() throws {
        let fileStore = InMemoryFileStore()
        let svc = AttachmentService(clock: FakeClock(), fileStore: fileStore)
        let att = try svc.save(id: "a1", data: Data([1, 2, 3]), kind: .jpeg)
        // Tamper with the file.
        try fileStore.write(data: Data([99, 99, 99]), to: att.fileURL!)
        XCTAssertThrowsError(try svc.get("a1")) { err in
            XCTAssertEqual(err as? AttachmentError, .tamperDetected)
        }
    }

    func testRetentionSweepDeletesPhysicalFiles() throws {
        let fileStore = InMemoryFileStore()
        let clock = FakeClock()
        let svc = AttachmentService(clock: clock, fileStore: fileStore)
        let att = try svc.save(id: "old", data: Data([1]), kind: .pdf)
        XCTAssertTrue(fileStore.exists(at: att.fileURL!))
        clock.advance(by: 31 * 86_400)
        _ = svc.runRetentionSweep()
        XCTAssertFalse(fileStore.exists(at: att.fileURL!))
    }

    func testInMemoryFileStoreRoundTrip() throws {
        let store = InMemoryFileStore()
        try store.write(data: Data([1, 2, 3]), to: "/tmp/test")
        XCTAssertTrue(store.exists(at: "/tmp/test"))
        XCTAssertEqual(try store.read(from: "/tmp/test"), Data([1, 2, 3]))
        try store.delete(at: "/tmp/test")
        XCTAssertFalse(store.exists(at: "/tmp/test"))
    }

    func testInMemoryFileStoreReadMissingThrows() {
        let store = InMemoryFileStore()
        XCTAssertThrowsError(try store.read(from: "/nope"))
    }
}
