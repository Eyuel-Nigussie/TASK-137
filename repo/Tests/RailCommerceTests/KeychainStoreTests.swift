import XCTest
@testable import RailCommerce

final class KeychainStoreTests: XCTestCase {
    func testSetGetDelete() throws {
        let kc = InMemoryKeychain()
        try kc.set(Data("hi".utf8), forKey: "a")
        XCTAssertEqual(kc.get("a"), Data("hi".utf8))
        try kc.delete("a")
        XCTAssertNil(kc.get("a"))
    }

    func testDeleteMissingThrows() {
        let kc = InMemoryKeychain()
        XCTAssertThrowsError(try kc.delete("missing")) { error in
            XCTAssertEqual(error as? SecureStoreError, .notFound)
        }
    }

    func testSealedKeyIsReadOnly() throws {
        let kc = InMemoryKeychain()
        try kc.set(Data([1]), forKey: "h")
        kc.seal("h")
        XCTAssertTrue(kc.isSealed("h"))
        XCTAssertThrowsError(try kc.set(Data([2]), forKey: "h")) { error in
            XCTAssertEqual(error as? SecureStoreError, .readOnly)
        }
        XCTAssertThrowsError(try kc.delete("h")) { error in
            XCTAssertEqual(error as? SecureStoreError, .readOnly)
        }
    }

    func testAllKeysSortedAndSealOnMissing() {
        let kc = InMemoryKeychain()
        try? kc.set(Data([1]), forKey: "b")
        try? kc.set(Data([2]), forKey: "a")
        XCTAssertEqual(kc.allKeys(), ["a", "b"])
        kc.seal("unknown") // no-op
        XCTAssertFalse(kc.isSealed("unknown"))
    }
}
