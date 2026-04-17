import Foundation

public enum USState: String, CaseIterable, Codable, Sendable {
    case AL, AK, AZ, AR, CA, CO, CT, DE, FL, GA, HI, ID, IL, IN, IA, KS, KY, LA, ME, MD,
         MA, MI, MN, MS, MO, MT, NE, NV, NH, NJ, NM, NY, NC, ND, OH, OK, OR, PA, RI, SC,
         SD, TN, TX, UT, VT, VA, WA, WV, WI, WY, DC
}

public struct USAddress: Codable, Equatable, Sendable {
    public let id: String
    public let recipient: String
    public let line1: String
    public let line2: String?
    public let city: String
    public let state: USState
    public let zip: String
    public let isDefault: Bool
    /// Owner user id for per-user isolation. `nil` indicates a legacy/unscoped
    /// record (shared-device installs from before user isolation was enforced).
    /// New production writes always set this via `AddressBook.save(_:ownedBy:)`.
    public let ownerUserId: String?

    public init(id: String, recipient: String, line1: String, line2: String? = nil,
                city: String, state: USState, zip: String, isDefault: Bool = false,
                ownerUserId: String? = nil) {
        self.id = id
        self.recipient = recipient
        self.line1 = line1
        self.line2 = line2
        self.city = city
        self.state = state
        self.zip = zip
        self.isDefault = isDefault
        self.ownerUserId = ownerUserId
    }
}

public enum AddressValidationError: Error, Equatable {
    case emptyRecipient
    case emptyLine1
    case emptyCity
    case invalidZip
}

public enum AddressBookError: Error, Equatable {
    /// The in-memory mutation succeeded but the durable write failed; the
    /// in-memory state is rolled back before this error is thrown so callers
    /// do not see a "success" that disappears on restart.
    case persistenceFailed
}

public enum AddressValidator {
    public static func validate(_ address: USAddress) throws {
        if address.recipient.trimmingCharacters(in: .whitespaces).isEmpty {
            throw AddressValidationError.emptyRecipient
        }
        if address.line1.trimmingCharacters(in: .whitespaces).isEmpty {
            throw AddressValidationError.emptyLine1
        }
        if address.city.trimmingCharacters(in: .whitespaces).isEmpty {
            throw AddressValidationError.emptyCity
        }
        let zip = address.zip
        let valid5 = zip.count == 5 && zip.allSatisfy { $0.isNumber }
        let valid9 = zip.count == 10 && zip[zip.index(zip.startIndex, offsetBy: 5)] == "-"
            && zip.prefix(5).allSatisfy { $0.isNumber }
            && zip.suffix(4).allSatisfy { $0.isNumber }
        if !(valid5 || valid9) { throw AddressValidationError.invalidZip }
    }
}

public final class AddressBook {
    public static let persistencePrefix = "addressBook.addr."

    private(set) public var addresses: [USAddress] = []
    private let persistence: PersistenceStore?

    public init(_ initial: [USAddress] = [], persistence: PersistenceStore? = nil) {
        self.persistence = persistence
        self.addresses = initial
        hydrate()
    }

    @discardableResult
    public func save(_ address: USAddress) throws -> USAddress {
        try AddressValidator.validate(address)
        // Scope defaulting and "first address becomes default" semantics to the
        // address's owner so one user's save cannot demote another user's
        // default. Unowned (legacy) records use the shared unowned scope.
        let scopeOwner = address.ownerUserId
        let scoped = addresses.filter { $0.ownerUserId == scopeOwner }
        let snapshot = addresses
        addresses.removeAll { $0.id == address.id }
        var toStore = address
        if address.isDefault {
            addresses = addresses.map { existing in
                guard existing.ownerUserId == scopeOwner else { return existing }
                return USAddress(id: existing.id, recipient: existing.recipient, line1: existing.line1,
                                 line2: existing.line2, city: existing.city, state: existing.state,
                                 zip: existing.zip, isDefault: false,
                                 ownerUserId: existing.ownerUserId)
            }
        } else if scoped.isEmpty {
            toStore = USAddress(id: address.id, recipient: address.recipient, line1: address.line1,
                                line2: address.line2, city: address.city, state: address.state,
                                zip: address.zip, isDefault: true,
                                ownerUserId: address.ownerUserId)
        }
        addresses.append(toStore)
        do {
            try persistAll()
        } catch {
            addresses = snapshot
            throw AddressBookError.persistenceFailed
        }
        return toStore
    }

    /// User-scoped save: stamps the address with `ownerUserId` before persisting so
    /// reads via `addresses(for:)` return only this user's records.
    @discardableResult
    public func save(_ address: USAddress, ownedBy userId: String) throws -> USAddress {
        let owned = USAddress(id: address.id, recipient: address.recipient,
                              line1: address.line1, line2: address.line2,
                              city: address.city, state: address.state, zip: address.zip,
                              isDefault: address.isDefault, ownerUserId: userId)
        return try save(owned)
    }

    public func remove(id: String) {
        let snapshot = addresses
        addresses.removeAll { $0.id == id }
        do { try persistAll() } catch { addresses = snapshot }
    }

    /// User-scoped remove: only deletes the record if the caller's user owns it.
    /// Prevents a signed-in user from erasing another user's address on a shared device.
    public func remove(id: String, ownedBy userId: String) {
        let snapshot = addresses
        addresses.removeAll { $0.id == id && $0.ownerUserId == userId }
        do { try persistAll() } catch { addresses = snapshot }
    }

    public var defaultAddress: USAddress? {
        addresses.first(where: { $0.isDefault }) ?? addresses.first
    }

    /// Returns addresses owned by `userId`. Other users' records — and legacy
    /// unowned records — are excluded so one account cannot view another's data.
    public func addresses(for userId: String) -> [USAddress] {
        addresses.filter { $0.ownerUserId == userId }
    }

    /// Default address scoped to a specific user.
    public func defaultAddress(for userId: String) -> USAddress? {
        let scoped = addresses(for: userId)
        return scoped.first(where: { $0.isDefault }) ?? scoped.first
    }

    // MARK: - Persistence

    private func persistAll() throws {
        guard let persistence else { return }
        try persistence.deleteAll(prefix: Self.persistencePrefix)
        let encoder = JSONEncoder()
        for addr in addresses {
            let data = try encoder.encode(addr)
            try persistence.save(key: Self.persistencePrefix + addr.id, data: data)
        }
    }

    private func hydrate() {
        guard let persistence else { return }
        do {
            let entries = try persistence.loadAll(prefix: Self.persistencePrefix)
            let decoder = JSONDecoder()
            for entry in entries {
                if let addr = try? decoder.decode(USAddress.self, from: entry.data) {
                    addresses.append(addr)
                }
            }
        } catch { /* hydration best-effort */ }
    }
}
