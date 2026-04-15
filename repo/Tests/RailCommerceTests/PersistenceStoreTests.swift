import XCTest
@testable import RailCommerce

final class PersistenceStoreTests: XCTestCase {

    private func store() -> InMemoryPersistenceStore { InMemoryPersistenceStore() }

    // MARK: - save / load

    func testSaveAndLoad() throws {
        let s = store()
        let data = Data([1, 2, 3])
        try s.save(key: "k1", data: data)
        XCTAssertEqual(try s.load(key: "k1"), data)
    }

    func testLoadMissingKeyReturnsNil() throws {
        XCTAssertNil(try store().load(key: "missing"))
    }

    func testOverwritesExistingKey() throws {
        let s = store()
        try s.save(key: "k1", data: Data([1]))
        try s.save(key: "k1", data: Data([2]))
        XCTAssertEqual(try s.load(key: "k1"), Data([2]))
    }

    // MARK: - loadAll(prefix:)

    func testLoadAllMatchingPrefix() throws {
        let s = store()
        try s.save(key: "user.1", data: Data([10]))
        try s.save(key: "user.2", data: Data([20]))
        try s.save(key: "order.1", data: Data([30]))
        let results = try s.loadAll(prefix: "user.")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.map { $0.key }, ["user.1", "user.2"])
    }

    func testLoadAllNonMatchingPrefixReturnsEmpty() throws {
        let s = store()
        try s.save(key: "order.1", data: Data([1]))
        let results = try s.loadAll(prefix: "user.")
        XCTAssertTrue(results.isEmpty)
    }

    func testLoadAllSortedByKey() throws {
        let s = store()
        try s.save(key: "k.3", data: Data([3]))
        try s.save(key: "k.1", data: Data([1]))
        try s.save(key: "k.2", data: Data([2]))
        let keys = try s.loadAll(prefix: "k.").map { $0.key }
        XCTAssertEqual(keys, ["k.1", "k.2", "k.3"])
    }

    // MARK: - delete

    func testDeleteRemovesKey() throws {
        let s = store()
        try s.save(key: "k1", data: Data([1]))
        try s.delete(key: "k1")
        XCTAssertNil(try s.load(key: "k1"))
    }

    func testDeleteMissingKeyIsNoOp() throws {
        XCTAssertNoThrow(try store().delete(key: "nope"))
    }

    // MARK: - deleteAll(prefix:)

    func testDeleteAllRemovesMatchingPrefix() throws {
        let s = store()
        try s.save(key: "msg.1", data: Data([1]))
        try s.save(key: "msg.2", data: Data([2]))
        try s.save(key: "order.1", data: Data([3]))
        try s.deleteAll(prefix: "msg.")
        XCTAssertNil(try s.load(key: "msg.1"))
        XCTAssertNil(try s.load(key: "msg.2"))
        XCTAssertNotNil(try s.load(key: "order.1"))
    }

    func testDeleteAllNonMatchingPrefixLeavesStoreIntact() throws {
        let s = store()
        try s.save(key: "order.1", data: Data([1]))
        try s.deleteAll(prefix: "msg.")
        XCTAssertNotNil(try s.load(key: "order.1"))
    }

    // MARK: - PersistenceError round-trip

    func testPersistenceErrorEquality() {
        XCTAssertEqual(PersistenceError.encodingFailed, PersistenceError.encodingFailed)
        XCTAssertEqual(PersistenceError.decodingFailed, PersistenceError.decodingFailed)
        XCTAssertNotEqual(PersistenceError.encodingFailed, PersistenceError.decodingFailed)
    }
}
