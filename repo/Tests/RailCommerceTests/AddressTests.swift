import XCTest
@testable import RailCommerce

final class AddressTests: XCTestCase {
    private func validAddress(id: String = "a1", isDefault: Bool = false,
                              zip: String = "10001") -> USAddress {
        USAddress(id: id, recipient: "Alice", line1: "1 Main", line2: nil,
                  city: "NYC", state: .NY, zip: zip, isDefault: isDefault)
    }

    func testValidateHappyPath5() throws {
        try AddressValidator.validate(validAddress())
    }

    func testValidateZipPlus4() throws {
        try AddressValidator.validate(validAddress(zip: "10001-1234"))
    }

    func testEmptyRecipient() {
        let a = USAddress(id: "a", recipient: "  ", line1: "1", line2: nil,
                          city: "x", state: .NY, zip: "12345")
        XCTAssertThrowsError(try AddressValidator.validate(a)) { error in
            XCTAssertEqual(error as? AddressValidationError, .emptyRecipient)
        }
    }

    func testEmptyLine1() {
        let a = USAddress(id: "a", recipient: "x", line1: " ", line2: nil,
                          city: "x", state: .NY, zip: "12345")
        XCTAssertThrowsError(try AddressValidator.validate(a)) { error in
            XCTAssertEqual(error as? AddressValidationError, .emptyLine1)
        }
    }

    func testEmptyCity() {
        let a = USAddress(id: "a", recipient: "x", line1: "1", line2: nil,
                          city: " ", state: .NY, zip: "12345")
        XCTAssertThrowsError(try AddressValidator.validate(a)) { error in
            XCTAssertEqual(error as? AddressValidationError, .emptyCity)
        }
    }

    func testInvalidZips() {
        for bad in ["abcde", "1234", "123456", "12345-abcd", "12345_6789"] {
            XCTAssertThrowsError(try AddressValidator.validate(validAddress(zip: bad))) { error in
                XCTAssertEqual(error as? AddressValidationError, .invalidZip)
            }
        }
    }

    func testAddressBookSaveAndPromoteFirstToDefault() throws {
        let book = AddressBook()
        let saved = try book.save(validAddress(id: "a1"))
        XCTAssertTrue(saved.isDefault, "first saved address becomes default")
        XCTAssertEqual(book.defaultAddress?.id, "a1")
    }

    func testAddressBookMakingNewDefaultDemotesOthers() throws {
        let book = AddressBook()
        try book.save(validAddress(id: "a1"))
        try book.save(validAddress(id: "a2", isDefault: true))
        XCTAssertEqual(book.defaultAddress?.id, "a2")
        XCTAssertTrue(book.addresses.first { $0.id == "a1" }!.isDefault == false)
    }

    func testAddressBookInitialArray() {
        let existing = USAddress(id: "seed", recipient: "S", line1: "L",
                                 city: "C", state: .CA, zip: "90210", isDefault: true)
        let book = AddressBook([existing])
        XCTAssertEqual(book.addresses.count, 1)
    }

    func testAddressBookReplaceSameId() throws {
        let book = AddressBook()
        try book.save(validAddress(id: "a1"))
        try book.save(validAddress(id: "a1"))
        XCTAssertEqual(book.addresses.count, 1)
    }

    func testAddressBookRemove() throws {
        let book = AddressBook()
        try book.save(validAddress(id: "a1"))
        book.remove(id: "a1")
        XCTAssertNil(book.defaultAddress)
    }

    func testAddressBookValidationPropagates() {
        let book = AddressBook()
        XCTAssertThrowsError(try book.save(validAddress(zip: "bad")))
    }

    func testUSStateRoundTrip() throws {
        for state in USState.allCases {
            let data = try JSONEncoder().encode(state)
            XCTAssertEqual(try JSONDecoder().decode(USState.self, from: data), state)
        }
    }

    func testDefaultAddressFallbackToFirst() throws {
        let book = AddressBook()
        var a = validAddress(id: "a1")
        try book.save(a)
        // Mutate the stored entry to be non-default so the fallback path fires.
        a = USAddress(id: "a2", recipient: "B", line1: "L", city: "C", state: .NY, zip: "12345")
        try book.save(a)
        XCTAssertNotNil(book.defaultAddress)
    }
}
