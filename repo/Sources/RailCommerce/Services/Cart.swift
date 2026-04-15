import Foundation

public struct CartLine: Codable, Equatable, Sendable {
    public let sku: SKU
    public var quantity: Int
    public var notes: String

    public init(sku: SKU, quantity: Int, notes: String = "") {
        self.sku = sku
        self.quantity = max(0, quantity)
        self.notes = notes
    }

    public var subtotalCents: Int { sku.priceCents * quantity }
}

public enum CartError: Error, Equatable {
    case unknownSku
    case nonPositiveQuantity
    case lineNotFound
}

public struct BundleSuggestion: Equatable, Sendable {
    public let bundleId: String
    public let title: String
    public let missing: [String]
    public let savingsCents: Int
}

/// Full CRUD cart. Uses a provided catalog for item lookup so tests are deterministic.
public final class Cart {
    private(set) public var lines: [CartLine] = []
    private let catalog: Catalog

    public init(catalog: Catalog) { self.catalog = catalog }

    @discardableResult
    public func add(skuId: String, quantity: Int, notes: String = "") throws -> CartLine {
        guard quantity > 0 else { throw CartError.nonPositiveQuantity }
        guard let sku = catalog.get(skuId) else { throw CartError.unknownSku }
        if let idx = lines.firstIndex(where: { $0.sku.id == skuId }) {
            lines[idx].quantity += quantity
            if !notes.isEmpty { lines[idx].notes = notes }
            return lines[idx]
        } else {
            let line = CartLine(sku: sku, quantity: quantity, notes: notes)
            lines.append(line)
            return line
        }
    }

    public func update(skuId: String, quantity: Int) throws {
        guard quantity >= 0 else { throw CartError.nonPositiveQuantity }
        guard let idx = lines.firstIndex(where: { $0.sku.id == skuId }) else {
            throw CartError.lineNotFound
        }
        if quantity == 0 {
            lines.remove(at: idx)
        } else {
            lines[idx].quantity = quantity
        }
    }

    public func remove(skuId: String) throws {
        guard let idx = lines.firstIndex(where: { $0.sku.id == skuId }) else {
            throw CartError.lineNotFound
        }
        lines.remove(at: idx)
    }

    public func clear() { lines.removeAll() }

    public var subtotalCents: Int { lines.reduce(0) { $0 + $1.subtotalCents } }
    public var isEmpty: Bool { lines.isEmpty }

    /// Suggest bundles whose children overlap at least one cart SKU but have missing members.
    /// Savings = sum(children prices) - bundle price.
    public func bundleSuggestions() -> [BundleSuggestion] {
        let ownedIds = Set(lines.map { $0.sku.id })
        var suggestions: [BundleSuggestion] = []
        for sku in catalog.all where sku.kind == .bundle && !sku.bundleChildren.isEmpty {
            let children = sku.bundleChildren
            let owned = children.filter { ownedIds.contains($0) }
            let missing = children.filter { !ownedIds.contains($0) }
            guard !owned.isEmpty, !missing.isEmpty else { continue }
            let childPriceSum = children.compactMap { catalog.get($0)?.priceCents }.reduce(0, +)
            let savings = max(0, childPriceSum - sku.priceCents)
            suggestions.append(BundleSuggestion(bundleId: sku.id, title: sku.title,
                                                missing: missing, savingsCents: savings))
        }
        return suggestions.sorted { $0.savingsCents > $1.savingsCents }
    }
}
