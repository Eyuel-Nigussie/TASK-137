import Foundation

/// Generic key-value persistence abstraction.
///
/// The iOS production target uses a Realm-backed implementation with an encryption
/// key retrieved from the iOS Keychain. Tests and Linux CI use `InMemoryPersistenceStore`.
public protocol PersistenceStore {
    /// Persists raw `data` under `key`, overwriting any previous value.
    func save(key: String, data: Data) throws
    /// Returns the data stored under `key`, or `nil` if the key is absent.
    func load(key: String) throws -> Data?
    /// Returns all entries whose key starts with `prefix`, sorted by key.
    func loadAll(prefix: String) throws -> [(key: String, data: Data)]
    /// Removes the entry for `key`. A no-op if the key does not exist.
    func delete(key: String) throws
    /// Removes all entries whose key starts with `prefix`.
    func deleteAll(prefix: String) throws
}

/// Domain-level error from the persistence layer.
public enum PersistenceError: Error, Equatable {
    case encodingFailed
    case decodingFailed
}

// MARK: - In-memory implementation (tests + Linux CI)

/// Thread-unsafe in-memory implementation. Suitable for unit tests and Linux CI where
/// a real on-device Realm database is not required.
public final class InMemoryPersistenceStore: PersistenceStore {
    private var store: [String: Data] = [:]
    public init() {}

    public func save(key: String, data: Data) throws {
        store[key] = data
    }

    public func load(key: String) throws -> Data? {
        store[key]
    }

    public func loadAll(prefix: String) throws -> [(key: String, data: Data)] {
        store
            .filter { $0.key.hasPrefix(prefix) }
            .map { (key: $0.key, data: $0.value) }
            .sorted { $0.key < $1.key }
    }

    public func delete(key: String) throws {
        store.removeValue(forKey: key)
    }

    public func deleteAll(prefix: String) throws {
        let keys = store.keys.filter { $0.hasPrefix(prefix) }
        for k in keys { store.removeValue(forKey: k) }
    }
}

// MARK: - Realm implementation stub (compiled only when RealmSwift is available)

#if canImport(RealmSwift)
import RealmSwift

/// Realm-backed persistence store with optional encryption key from the iOS Keychain.
///
/// Usage (iOS app entry point):
/// ```swift
/// let encKey = KeychainStore.encryptionKey()  // 64-byte key sealed in Keychain
/// let config = Realm.Configuration(encryptionKey: encKey)
/// let store = RealmPersistenceStore(configuration: config)
/// ```
public final class RealmPersistenceStore: PersistenceStore {

    private class Entry: Object {
        @Persisted(primaryKey: true) var key: String = ""
        @Persisted var payload: Data = Data()
    }

    private let configuration: Realm.Configuration

    public init(configuration: Realm.Configuration = .defaultConfiguration) {
        self.configuration = configuration
    }

    private func realm() throws -> Realm {
        try Realm(configuration: configuration)
    }

    public func save(key: String, data: Data) throws {
        let entry = Entry()
        entry.key = key
        entry.payload = data
        let r = try realm()
        try r.write { r.add(entry, update: .modified) }
    }

    public func load(key: String) throws -> Data? {
        try realm().object(ofType: Entry.self, forPrimaryKey: key)?.payload
    }

    public func loadAll(prefix: String) throws -> [(key: String, data: Data)] {
        try realm().objects(Entry.self)
            .filter("key BEGINSWITH %@", prefix)
            .sorted(byKeyPath: "key")
            .map { (key: $0.key, data: $0.payload) }
    }

    public func delete(key: String) throws {
        let r = try realm()
        if let entry = r.object(ofType: Entry.self, forPrimaryKey: key) {
            try r.write { r.delete(entry) }
        }
    }

    public func deleteAll(prefix: String) throws {
        let r = try realm()
        let entries = r.objects(Entry.self).filter("key BEGINSWITH %@", prefix)
        try r.write { r.delete(entries) }
    }
}
#endif
