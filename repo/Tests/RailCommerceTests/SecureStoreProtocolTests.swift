import XCTest
@testable import RailCommerce

/// Tests for the `SecureStore` protocol itself, including its default `seal`/`isSealed`
/// no-op implementation. Ensures polymorphic callers can `seal` uniformly without
/// type-casting.
final class SecureStoreProtocolTests: XCTestCase {

    /// A deliberately minimal `SecureStore` conformer that does NOT override `seal`
    /// or `isSealed`. Used to assert that the protocol defaults compile and execute
    /// as no-ops.
    final class BareStore: SecureStore {
        var storage: [String: Data] = [:]
        func set(_ value: Data, forKey key: String) throws { storage[key] = value }
        func get(_ key: String) -> Data? { storage[key] }
        func delete(_ key: String) throws {
            guard storage.removeValue(forKey: key) != nil else { throw SecureStoreError.notFound }
        }
        func allKeys() -> [String] { Array(storage.keys).sorted() }
    }

    func testDefaultSealIsNoOp() throws {
        let store: SecureStore = BareStore()
        try store.set(Data([1]), forKey: "k")
        store.seal("k")
        // Value should remain mutable because the default seal is a no-op.
        XCTAssertNoThrow(try store.set(Data([2]), forKey: "k"))
        XCTAssertEqual(store.get("k"), Data([2]))
    }

    func testDefaultIsSealedAlwaysFalse() {
        let store: SecureStore = BareStore()
        XCTAssertFalse(store.isSealed("anything"))
    }

    // MARK: - InMemoryKeychain overrides

    func testInMemoryKeychainSealIsEnforced() throws {
        let kc = InMemoryKeychain()
        try kc.set(Data([1]), forKey: "k")
        kc.seal("k")
        XCTAssertTrue(kc.isSealed("k"))
        XCTAssertThrowsError(try kc.set(Data([2]), forKey: "k")) { err in
            XCTAssertEqual(err as? SecureStoreError, .readOnly)
        }
    }

    func testInMemoryKeychainSealOnNonExistentKeyIsNoOp() {
        let kc = InMemoryKeychain()
        kc.seal("ghost")
        XCTAssertFalse(kc.isSealed("ghost"))
    }

    // MARK: - SecureStoreError

    func testSecureStoreErrorEquality() {
        XCTAssertEqual(SecureStoreError.notFound, SecureStoreError.notFound)
        XCTAssertEqual(SecureStoreError.readOnly, SecureStoreError.readOnly)
        XCTAssertNotEqual(SecureStoreError.notFound, SecureStoreError.readOnly)
    }

    // MARK: - Polymorphic usage

    func testCheckoutServiceUsesSealPolymorphically() throws {
        // A SecureStore that is NOT an InMemoryKeychain (uses the protocol default).
        let store = BareStore()
        let catalog = Catalog([SKU(id: "t", kind: .ticket, title: "T", priceCents: 100)])
        let cart = Cart(catalog: catalog)
        try cart.add(skuId: "t", quantity: 1)
        let clock = FakeClock()
        let svc = CheckoutService(clock: clock, keychain: store)
        let alice = User(id: "alice", displayName: "Alice", role: .customer)
        let address = USAddress(id: "a", recipient: "A", line1: "1 Main",
                                city: "NYC", state: .NY, zip: "10001")
        let shipping = ShippingTemplate(id: "s", name: "Std", feeCents: 0, etaDays: 1)
        _ = try svc.submit(orderId: "O1", userId: "alice", cart: cart, discounts: [],
                           address: address, shipping: shipping,
                           invoiceNotes: "", actingUser: alice)
        // No cast needed — service calls `store.seal(...)` via the protocol default.
        XCTAssertNotNil(svc.storedHash(for: "O1"))
    }
}
