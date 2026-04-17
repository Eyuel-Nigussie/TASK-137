import Foundation

public struct StoredAttachment: Codable, Equatable, Sendable {
    public let id: String
    public let sandboxPath: String
    /// Absolute file URL for on-disk access. Nil only when using in-memory sandbox.
    public let fileURL: String?
    public let sizeBytes: Int
    public let kind: AttachmentKind
    public let storedAt: Date
    /// SHA-256 hex of the stored bytes, computed at save and re-verified on read.
    public let sha256: String?
}

public enum AttachmentError: Error, Equatable {
    case tooLarge
    case invalidType
    case notFound
    case persistenceFailed
    case tamperDetected
}

/// Abstraction over the file system so tests can run without disk I/O.
public protocol AttachmentFileStore {
    func write(data: Data, to path: String) throws
    func read(from path: String) throws -> Data
    func delete(at path: String) throws
    func exists(at path: String) -> Bool
}

/// Real file system implementation used in production.
public final class DiskFileStore: AttachmentFileStore {
    public init() {}
    public func write(data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // `.completeFileProtection` is an Apple-platform-only
        // `Data.WritingOptions` value; it does not exist on Linux
        // Foundation. Linux writes without that option — the iOS build
        // keeps the Keychain-style file protection guarantee.
        #if canImport(Darwin)
        try data.write(to: url, options: .completeFileProtection)
        #else
        try data.write(to: url)
        #endif
    }
    public func read(from path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }
    public func delete(at path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }
    public func exists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// In-memory file store for tests.
public final class InMemoryFileStore: AttachmentFileStore {
    private var files: [String: Data] = [:]
    public init() {}
    public func write(data: Data, to path: String) throws { files[path] = data }
    public func read(from path: String) throws -> Data {
        guard let d = files[path] else { throw AttachmentError.notFound }
        return d
    }
    public func delete(at path: String) throws { files.removeValue(forKey: path) }
    public func exists(at path: String) -> Bool { files[path] != nil }
    public var count: Int { files.count }
}

/// Resolves the set of attachment IDs currently referenced by another domain
/// (messaging bodies, after-sales photo proof, content media refs, etc.).
/// Injected into `AttachmentService` so the cleanup sweep can protect live
/// references from deletion even when they are older than the retention window.
public typealias AttachmentReferenceResolver = () -> Set<String>

public final class AttachmentService {
    public static let maxBytes = 10 * 1024 * 1024
    public static let retentionDays = 30
    public static let persistencePrefix = "attachment."

    private let clock: any Clock
    private let persistence: PersistenceStore?
    private let fileStore: AttachmentFileStore
    private let basePath: String
    private let logger: Logger
    private var store: [String: StoredAttachment] = [:]
    /// Producers of the "live references" set. Summed at sweep time so the sweep
    /// sees a consistent snapshot of every domain's current attachment references.
    private var referenceResolvers: [AttachmentReferenceResolver] = []

    public init(clock: any Clock,
                persistence: PersistenceStore? = nil,
                fileStore: AttachmentFileStore = InMemoryFileStore(),
                basePath: String = NSTemporaryDirectory() + "railcommerce-attachments",
                logger: Logger = SilentLogger()) {
        self.clock = clock
        self.persistence = persistence
        self.fileStore = fileStore
        self.basePath = basePath
        self.logger = logger
        hydrate()
    }

    /// Registers a resolver that enumerates attachment IDs currently referenced
    /// by some domain. The composition root (`RailCommerce.init`) registers one
    /// resolver per service that holds attachment references so the sweep below
    /// sees the full reference graph.
    public func registerReferenceResolver(_ resolver: @escaping AttachmentReferenceResolver) {
        referenceResolvers.append(resolver)
    }

    @discardableResult
    public func save(id: String, data: Data, kind: AttachmentKind) throws -> StoredAttachment {
        guard data.count <= Self.maxBytes else { throw AttachmentError.tooLarge }
        let hashHex = SHA256.hex(SHA256.digest(data))
        let relativePath = "attachments/\(id).\(kind.rawValue)"
        let absolutePath = basePath + "/" + relativePath
        try fileStore.write(data: data, to: absolutePath)
        let att = StoredAttachment(id: id, sandboxPath: relativePath,
                                   fileURL: absolutePath,
                                   sizeBytes: data.count, kind: kind,
                                   storedAt: clock.now(), sha256: hashHex)
        store[id] = att
        try persist(att)
        logger.info(.persistence, "attachment save id=\(id) size=\(data.count) kind=\(kind.rawValue)")
        return att
    }

    /// Reads the attachment metadata plus verifies on-disk integrity.
    public func get(_ id: String) throws -> StoredAttachment {
        guard let a = store[id] else { throw AttachmentError.notFound }
        // Verify hash on read if file exists.
        if let filePath = a.fileURL, let expectedHash = a.sha256,
           fileStore.exists(at: filePath) {
            let data = try fileStore.read(from: filePath)
            let actualHash = SHA256.hex(SHA256.digest(data))
            if actualHash != expectedHash {
                logger.error(.persistence, "attachment tamper detected id=\(id)")
                throw AttachmentError.tamperDetected
            }
        }
        return a
    }

    /// Reads the raw bytes for an attachment.
    public func readData(_ id: String) throws -> Data {
        guard let a = store[id], let filePath = a.fileURL else {
            throw AttachmentError.notFound
        }
        return try fileStore.read(from: filePath)
    }

    public func all() -> [StoredAttachment] {
        store.values.sorted { $0.id < $1.id }
    }

    /// Returns the union of all registered reference sets — the attachments that
    /// are currently "live" in some domain and therefore must not be swept even
    /// when older than the retention window.
    public func liveReferences() -> Set<String> {
        var all: Set<String> = []
        for resolver in referenceResolvers { all.formUnion(resolver()) }
        return all
    }

    /// Runs the 30-day cleanup policy. An attachment is deleted only when it is
    /// **both** older than `retentionDays` **and** not referenced by any registered
    /// domain (messaging, after-sales photo proof, content media). This matches the
    /// prompt's "delete unreferenced files after 30 days" requirement — simply being
    /// old is not enough; a still-used attachment stays until its last reference is
    /// removed.
    @discardableResult
    public func runRetentionSweep() -> [String] {
        let cutoff = clock.now().addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        let live = liveReferences()
        let toDelete = store.values
            .filter { $0.storedAt < cutoff && !live.contains($0.id) }
            .map { $0.id }
        let skippedAged = store.values
            .filter { $0.storedAt < cutoff && live.contains($0.id) }
            .count
        for id in toDelete {
            if let filePath = store[id]?.fileURL {
                try? fileStore.delete(at: filePath)
            }
            store.removeValue(forKey: id)
            try? persistence?.delete(key: Self.persistencePrefix + id)
        }
        logger.info(.persistence,
                    "attachment sweep purged=\(toDelete.count) skippedStillReferenced=\(skippedAged)")
        return toDelete.sorted()
    }

    // MARK: - Persistence

    private func persist(_ att: StoredAttachment) throws {
        guard let persistence else { return }
        do {
            let data = try JSONEncoder().encode(att)
            try persistence.save(key: Self.persistencePrefix + att.id, data: data)
        } catch {
            logger.error(.persistence, "attachment persist failed id=\(att.id)")
            throw AttachmentError.persistenceFailed
        }
    }

    private func hydrate() {
        guard let persistence else { return }
        do {
            for entry in try persistence.loadAll(prefix: Self.persistencePrefix) {
                if let a = try? JSONDecoder().decode(StoredAttachment.self, from: entry.data) {
                    store[a.id] = a
                }
            }
        } catch {
            logger.error(.persistence, "attachment hydrate failed err=\(error)")
        }
    }
}
