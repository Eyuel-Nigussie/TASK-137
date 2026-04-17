import XCTest
@testable import RailCommerceApp
@testable import RailCommerce

/// Exercises `SystemKeychain` — the real iOS Keychain-backed `SecureStore`
/// implementation. Runs only on an iOS Simulator (the Keychain entitlement
/// is not available in Swift Package tests on macOS).
final class SystemKeychainTests: XCTestCase {

    private var keychain: SystemKeychain!

    override func setUp() {
        super.setUp()
        keychain = SystemKeychain()
        // Clear any prior-run artifacts so tests are hermetic.
        for key in keychain.allKeys() {
            try? keychain.delete(key)
        }
    }

    override func tearDown() {
        for key in keychain.allKeys() {
            try? keychain.delete(key)
        }
        keychain = nil
        super.tearDown()
    }

    // MARK: - Round-trip

    func testSetAndGetRoundTripReturnsOriginalBytes() throws {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try keychain.set(payload, forKey: "rctest.set.get")
        XCTAssertEqual(keychain.get("rctest.set.get"), payload)
    }

    func testOverwriteReplacesValue() throws {
        try keychain.set(Data([1]), forKey: "rctest.overwrite")
        try keychain.set(Data([2, 3]), forKey: "rctest.overwrite")
        XCTAssertEqual(keychain.get("rctest.overwrite"), Data([2, 3]))
    }

    func testGetMissingKeyReturnsNil() {
        XCTAssertNil(keychain.get("rctest.missing.\(UUID().uuidString)"))
    }

    // MARK: - Delete

    func testDeleteRemovesKey() throws {
        try keychain.set(Data([1]), forKey: "rctest.delete")
        try keychain.delete("rctest.delete")
        XCTAssertNil(keychain.get("rctest.delete"))
    }

    // MARK: - allKeys

    func testAllKeysReportsOwnedKeys() throws {
        try keychain.set(Data([1]), forKey: "rctest.list.a")
        try keychain.set(Data([2]), forKey: "rctest.list.b")
        let keys = keychain.allKeys()
        XCTAssertTrue(keys.contains("rctest.list.a"))
        XCTAssertTrue(keys.contains("rctest.list.b"))
    }

    // MARK: - Seal / integrity

    /// SystemKeychain implements `seal` via an HMAC signature stored alongside
    /// the value. `get` on a sealed key verifies the signature and returns nil
    /// on mismatch. This round-trip asserts the happy path.
    func testSealedReadSucceedsWhenUntampered() throws {
        // Per-run unique key so a prior sealed entry from an interrupted test
        // run cannot contaminate this one. Sealed keys are intentionally
        // immutable; cleanup via delete throws `readOnly` and is expected.
        let key = "rctest.sealed.happy.\(UUID().uuidString)"
        try keychain.set(Data([42]), forKey: key)
        keychain.seal(key)
        XCTAssertTrue(keychain.isSealed(key))
        XCTAssertEqual(keychain.get(key), Data([42]),
                       "sealed read must still return the stored bytes when the sig is valid")
    }
}
