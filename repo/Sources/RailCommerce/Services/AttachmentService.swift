import Foundation

public struct StoredAttachment: Codable, Equatable, Sendable {
    public let id: String
    public let sandboxPath: String
    public let sizeBytes: Int
    public let kind: AttachmentKind
    public let storedAt: Date
}

public enum AttachmentError: Error, Equatable {
    case tooLarge
    case invalidType
    case notFound
}

public final class AttachmentService {
    public static let maxBytes = 10 * 1024 * 1024
    public static let retentionDays = 30

    private let clock: Clock
    private var store: [String: StoredAttachment] = [:]

    public init(clock: Clock) { self.clock = clock }

    @discardableResult
    public func save(id: String, data: Data, kind: AttachmentKind) throws -> StoredAttachment {
        guard data.count <= Self.maxBytes else { throw AttachmentError.tooLarge }
        let path = "app://sandbox/attachments/\(id).\(kind.rawValue)"
        let att = StoredAttachment(id: id, sandboxPath: path, sizeBytes: data.count,
                                   kind: kind, storedAt: clock.now())
        store[id] = att
        return att
    }

    public func get(_ id: String) throws -> StoredAttachment {
        guard let a = store[id] else { throw AttachmentError.notFound }
        return a
    }

    public func all() -> [StoredAttachment] {
        store.values.sorted { $0.id < $1.id }
    }

    /// Runs the 30-day cleanup policy. Returns IDs that were removed.
    @discardableResult
    public func runRetentionSweep() -> [String] {
        let cutoff = clock.now().addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        let expired = store.values.filter { $0.storedAt < cutoff }.map { $0.id }
        for id in expired { store.removeValue(forKey: id) }
        return expired.sorted()
    }
}
