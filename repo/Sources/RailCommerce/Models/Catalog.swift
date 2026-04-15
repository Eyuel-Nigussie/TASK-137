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
    private var items: [String: SKU] = [:]
    public init(_ items: [SKU] = []) { items.forEach { self.items[$0.id] = $0 } }

    public func upsert(_ sku: SKU) { items[sku.id] = sku }
    public func remove(id: String) { items.removeValue(forKey: id) }
    public func get(_ id: String) -> SKU? { items[id] }
    public var all: [SKU] { items.values.sorted { $0.id < $1.id } }

    public func filter(_ tag: TaxonomyTag) -> [SKU] {
        all.filter { $0.tag.matches(tag) }
    }
}
