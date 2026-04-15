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

    public init(id: String, recipient: String, line1: String, line2: String? = nil,
                city: String, state: USState, zip: String, isDefault: Bool = false) {
        self.id = id
        self.recipient = recipient
        self.line1 = line1
        self.line2 = line2
        self.city = city
        self.state = state
        self.zip = zip
        self.isDefault = isDefault
    }
}

public enum AddressValidationError: Error, Equatable {
    case emptyRecipient
    case emptyLine1
    case emptyCity
    case invalidZip
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
    private(set) public var addresses: [USAddress] = []

    public init(_ initial: [USAddress] = []) { self.addresses = initial }

    @discardableResult
    public func save(_ address: USAddress) throws -> USAddress {
        try AddressValidator.validate(address)
        addresses.removeAll { $0.id == address.id }
        var toStore = address
        if address.isDefault {
            addresses = addresses.map { existing in
                var copy = existing
                copy = USAddress(id: copy.id, recipient: copy.recipient, line1: copy.line1,
                                 line2: copy.line2, city: copy.city, state: copy.state,
                                 zip: copy.zip, isDefault: false)
                return copy
            }
        } else if addresses.isEmpty {
            toStore = USAddress(id: address.id, recipient: address.recipient, line1: address.line1,
                                line2: address.line2, city: address.city, state: address.state,
                                zip: address.zip, isDefault: true)
        }
        addresses.append(toStore)
        return toStore
    }

    public func remove(id: String) { addresses.removeAll { $0.id == id } }

    public var defaultAddress: USAddress? {
        addresses.first(where: { $0.isDefault }) ?? addresses.first
    }
}
