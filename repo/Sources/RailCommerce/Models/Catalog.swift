import Foundation

public enum SkuKind: String, Codable, Sendable {
    case ticket
    case merchandise
    case bundle
}

public struct SKU: Codable, Equatable, Sendable, Hashable {
    public let id: String
    public let kind: SkuKind
    public let title: String
    public let priceCents: Int
    public let tag: TaxonomyTag
    public let bundleChildren: [String]

    public init(id: String, kind: SkuKind, title: String, priceCents: Int,
                tag: TaxonomyTag = TaxonomyTag(), bundleChildren: [String] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.priceCents = priceCents
        self.tag = tag
        self.bundleChildren = bundleChildren
    }
}

public final class Catalog {
    public static let persistencePrefix = "catalog.sku."

    private var items: [String: SKU] = [:]
    private let persistence: PersistenceStore?

    public init(_ items: [SKU] = [], persistence: PersistenceStore? = nil) {
        self.persistence = persistence
        items.forEach { self.items[$0.id] = $0 }
        hydrate()
    }

    public func upsert(_ sku: SKU) {
        let prior = items[sku.id]
        items[sku.id] = sku
        do {
            try persistOne(sku)
        } catch {
            if let prior { items[sku.id] = prior }
            else { items.removeValue(forKey: sku.id) }
        }
    }

    public func remove(id: String) {
        let prior = items[id]
        items.removeValue(forKey: id)
        do {
            try persistence?.delete(key: Self.persistencePrefix + id)
        } catch {
            if let prior { items[id] = prior }
        }
    }

    public func get(_ id: String) -> SKU? { items[id] }
    public var all: [SKU] { items.values.sorted { $0.id < $1.id } }

    public func filter(_ tag: TaxonomyTag) -> [SKU] {
        all.filter { $0.tag.matches(tag) }
    }

    // MARK: - Persistence

    private func persistOne(_ sku: SKU) throws {
        guard let persistence else { return }
        let data = try JSONEncoder().encode(sku)
        try persistence.save(key: Self.persistencePrefix + sku.id, data: data)
    }

    private func hydrate() {
        guard let persistence else { return }
        let decoder = JSONDecoder()
        if let entries = try? persistence.loadAll(prefix: Self.persistencePrefix) {
            for entry in entries {
                if let sku = try? decoder.decode(SKU.self, from: entry.data) {
                    items[sku.id] = sku
                }
            }
        }
    }
}
