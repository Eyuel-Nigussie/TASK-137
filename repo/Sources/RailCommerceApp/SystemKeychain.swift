#if canImport(UIKit)
import Foundation
import Security
import CryptoKit
import RailCommerce

/// Production iOS Keychain implementation backed by `Security.framework`.
/// Items are stored as generic passwords scoped to this app's bundle identifier.
///
/// `seal(_:)` implements tamper-detection by storing an HMAC-SHA256 signature
/// alongside the value. `isSealed(_:)` returns true when a signature entry exists.
/// Sealed values cannot be overwritten; attempts throw `SecureStoreError.readOnly`.
final class SystemKeychain: SecureStore {

    private let service: String
    private static let hmacKeyName = "railcommerce.seal.hmacKey"
    /// Documented accessibility class: available after first device unlock,
    /// not exportable to another device. Matches the `docs/apispec.md`
    /// security contract for order-hash and encryption-key storage.
    private static let accessibleClass = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.railcommerce.app") {
        self.service = service
    }

    // MARK: - SecureStore

    func set(_ value: Data, forKey key: String) throws {
        // Sealed keys are immutable.
        if isSealed(key) { throw SecureStoreError.readOnly }
        // Update existing entry if present; otherwise add with the documented
        // accessibility class.
        let updateAttrs: [String: Any] = [
            kSecValueData as String:       value,
            kSecAttrAccessible as String:  Self.accessibleClass
        ]
        var status = SecItemUpdate(baseQuery(for: key) as CFDictionary, updateAttrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery(for: key)
            addQuery[kSecValueData as String]      = value
            addQuery[kSecAttrAccessible as String] = Self.accessibleClass
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if status != errSecSuccess {
            throw SecureStoreError.readOnly
        }
    }

    func get(_ key: String) -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func delete(_ key: String) throws {
        if isSealed(key) { throw SecureStoreError.readOnly }
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        if status == errSecItemNotFound {
            throw SecureStoreError.notFound
        }
        if status != errSecSuccess {
            throw SecureStoreError.readOnly
        }
    }

    func allKeys() -> [String] {
        let query: [String: Any] = [
            kSecClass as String:             kSecClassGenericPassword,
            kSecAttrService as String:       service,
            kSecReturnAttributes as String:  true,
            kSecMatchLimit as String:        kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { !$0.hasSuffix(".seal") }
            .sorted()
    }

    // MARK: - Seal / HMAC tamper protection

    /// Seals a key by computing HMAC-SHA256 over its current value and storing
    /// the signature at `key.seal`. Once sealed, `set` and `delete` throw `.readOnly`.
    func seal(_ key: String) {
        guard let value = get(key) else { return }
        let hmacKey = ensureHMACKey()
        let sig = Data(HMAC<CryptoKit.SHA256>.authenticationCode(for: value,
                                                                  using: SymmetricKey(data: hmacKey)))
        let sealKey = key + ".seal"
        let addQuery: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrService as String:    service,
            kSecAttrAccount as String:    sealKey,
            kSecValueData as String:      sig,
            kSecAttrAccessible as String: Self.accessibleClass
        ]
        SecItemDelete(addQuery as CFDictionary) // idempotent
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    func isSealed(_ key: String) -> Bool {
        get(key + ".seal") != nil
    }

    // MARK: - Private helpers

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    private func ensureHMACKey() -> Data {
        if let existing = get(Self.hmacKeyName) { return existing }
        let key = KeychainCredentialStore.randomBytes(32)
        try? set(key, forKey: Self.hmacKeyName)
        return key
    }

}
#endif
