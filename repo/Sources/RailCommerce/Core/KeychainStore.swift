import Foundation

/// Secret storage abstraction modelling the iOS Keychain. The production target would
/// back this with `Security.framework` / `SecItem*`; the in-memory implementation is used
/// in tests and on non-iOS platforms so that the business logic is fully portable.
public protocol SecureStore: AnyObject {
    func set(_ value: Data, forKey key: String) throws
    func get(_ key: String) -> Data?
    func delete(_ key: String) throws
    func allKeys() -> [String]
    /// Mark `key` as immutable. Implementations that can't enforce immutability at
    /// the store level (e.g. iOS Keychain) should layer an HMAC signature at the
    /// value level instead; the protocol-level default is a no-op so callers can
    /// call `seal` uniformly without casting.
    func seal(_ key: String)
    /// `true` if `key` has been sealed.
    func isSealed(_ key: String) -> Bool
}

public extension SecureStore {
    func seal(_ key: String) {}
    func isSealed(_ key: String) -> Bool { false }
}

public enum SecureStoreError: Error, Equatable {
    case notFound
    case readOnly
}

public final class InMemoryKeychain: SecureStore {
    private var storage: [String: Data] = [:]
    private var locked: Set<String> = []

    public init() {}

    public func set(_ value: Data, forKey key: String) throws {
        if locked.contains(key) { throw SecureStoreError.readOnly }
        storage[key] = value
    }

    public func get(_ key: String) -> Data? { storage[key] }

    public func delete(_ key: String) throws {
        if locked.contains(key) { throw SecureStoreError.readOnly }
        guard storage.removeValue(forKey: key) != nil else { throw SecureStoreError.notFound }
    }

    public func allKeys() -> [String] { Array(storage.keys).sorted() }

    /// Seal a key so it becomes immutable (used for order-snapshot hashes).
    public func seal(_ key: String) {
        if storage[key] != nil { locked.insert(key) }
    }

    public func isSealed(_ key: String) -> Bool { locked.contains(key) }
}
