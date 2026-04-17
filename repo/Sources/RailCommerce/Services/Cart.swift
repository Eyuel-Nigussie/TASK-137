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
    /// The in-memory mutation succeeded but the durable write failed; the cart's
    /// in-memory state is rolled back before this error is thrown so callers do
    /// not see a successful add/update/remove that disappears on restart.
    case persistenceFailed
}

public struct BundleSuggestion: Equatable, Sendable {
    public let bundleId: String
    public let title: String
    public let missing: [String]
    public let savingsCents: Int
}

/// Full CRUD cart. Uses a provided catalog for item lookup so tests are deterministic.
/// Optionally persists the line list so the cart survives app restarts.
///
/// When `ownerUserId` is provided, the persistence key is scoped to that user
/// (`cart.lines.<userId>`) so one user's cart cannot leak into another user's
/// session on a shared device. Unowned carts use the legacy shared key.
public final class Cart {
    public static let persistenceKey = "cart.lines"
    public static let persistenceKeyPrefix = "cart.lines."

    /// Owner user id — `nil` means legacy/unscoped cart (shared-key persistence).
    public let ownerUserId: String?

    private(set) public var lines: [CartLine] = []
    private let catalog: Catalog
    private let persistence: PersistenceStore?

    public init(catalog: Catalog, persistence: PersistenceStore? = nil,
                ownerUserId: String? = nil) {
        self.catalog = catalog
        self.persistence = persistence
        self.ownerUserId = ownerUserId
        hydrate()
    }

    /// The persistence key used for this cart. User-scoped when `ownerUserId` is set.
    public var persistenceKey: String {
        if let uid = ownerUserId { return Self.persistenceKeyPrefix + uid }
        return Self.persistenceKey
    }

    @discardableResult
    public func add(skuId: String, quantity: Int, notes: String = "") throws -> CartLine {
        guard quantity > 0 else { throw CartError.nonPositiveQuantity }
        guard let sku = catalog.get(skuId) else { throw CartError.unknownSku }
        let snapshot = lines
        if let idx = lines.firstIndex(where: { $0.sku.id == skuId }) {
            lines[idx].quantity += quantity
            if !notes.isEmpty { lines[idx].notes = notes }
            try persistOrRollback(snapshot)
            return lines[idx]
        } else {
            let line = CartLine(sku: sku, quantity: quantity, notes: notes)
            lines.append(line)
            try persistOrRollback(snapshot)
            return line
        }
    }

    public func update(skuId: String, quantity: Int) throws {
        guard quantity >= 0 else { throw CartError.nonPositiveQuantity }
        guard let idx = lines.firstIndex(where: { $0.sku.id == skuId }) else {
            throw CartError.lineNotFound
        }
        let snapshot = lines
        if quantity == 0 {
            lines.remove(at: idx)
        } else {
            lines[idx].quantity = quantity
        }
        try persistOrRollback(snapshot)
    }

    public func remove(skuId: String) throws {
        guard let idx = lines.firstIndex(where: { $0.sku.id == skuId }) else {
            throw CartError.lineNotFound
        }
        let snapshot = lines
        lines.remove(at: idx)
        try persistOrRollback(snapshot)
    }

    /// Empties the cart. Throws `CartError.persistenceFailed` and rolls back
    /// in-memory state if the durable write fails, so a caller never sees a
    /// successful clear that a restart would contradict.
    public func clear() throws {
        let snapshot = lines
        lines.removeAll()
        try persistOrRollback(snapshot)
    }

    public var subtotalCents: Int { lines.reduce(0) { $0 + $1.subtotalCents } }
    public var isEmpty: Bool { lines.isEmpty }

    // MARK: - Persistence

    /// Persists the current `lines`. On failure, restores `snapshot` into
    /// `lines` and throws `CartError.persistenceFailed` so callers cannot mistake
    /// a non-durable write for a successful mutation.
    private func persistOrRollback(_ snapshot: [CartLine]) throws {
        guard let persistence else { return }
        do {
            let data = try JSONEncoder().encode(lines)
            try persistence.save(key: persistenceKey, data: data)
        } catch {
            lines = snapshot
            throw CartError.persistenceFailed
        }
    }

    private func hydrate() {
        guard let persistence else { return }
        // `load` returns `Data?` wrapped in `throws`; `try?` yields `Data??` —
        // unwrap both layers explicitly.
        let inner: Data?
        do {
            inner = try persistence.load(key: persistenceKey)
        } catch {
            return
        }
        guard let data = inner,
              let hydrated = try? JSONDecoder().decode([CartLine].self, from: data) else {
            return
        }
        lines = hydrated
    }

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
