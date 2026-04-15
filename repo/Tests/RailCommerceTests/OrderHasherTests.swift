import XCTest
@testable import RailCommerce

final class OrderHasherTests: XCTestCase {
    func testKnownSHA256Vectors() {
        // Empty
        XCTAssertEqual(SHA256.hex(SHA256.digest(Data())),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // "abc"
        XCTAssertEqual(SHA256.hex(SHA256.digest(Data("abc".utf8))),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testMultiBlockInput() {
        // Length > 64 to exercise multiple chunks and extra padding.
        let long = String(repeating: "a", count: 120)
        let hex = SHA256.hex(SHA256.digest(Data(long.utf8)))
        XCTAssertEqual(hex.count, 64)
    }

    func testOrderHashStableRegardlessOfKeyOrder() {
        let a: [String: String] = ["z": "1", "a": "2", "m": "3"]
        let b: [String: String] = ["a": "2", "m": "3", "z": "1"]
        XCTAssertEqual(OrderHasher.hash(snapshot: a), OrderHasher.hash(snapshot: b))
    }

    func testOrderHashChangesWithPayload() {
        let a = OrderHasher.hash(snapshot: ["id": "1"])
        let b = OrderHasher.hash(snapshot: ["id": "2"])
        XCTAssertNotEqual(a, b)
    }
}
