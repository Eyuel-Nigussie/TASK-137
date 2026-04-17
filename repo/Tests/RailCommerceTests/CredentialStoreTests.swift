import XCTest
@testable import RailCommerce

/// Tests for `KeychainCredentialStore`: password policy, hash stability, salt
/// independence, peppering, constant-time compare, and enrollment flows.
final class CredentialStoreTests: XCTestCase {

    private let alice = User(id: "alice", displayName: "Alice", role: .customer)
    private let bob = User(id: "bob", displayName: "Bob", role: .customer)

    private func store(salt: Data = Data(repeating: 0x01, count: 32)) -> (KeychainCredentialStore, InMemoryKeychain) {
        let kc = InMemoryKeychain()
        let cs = KeychainCredentialStore(keychain: kc, saltProvider: { salt })
        return (cs, kc)
    }

    // MARK: - Password policy

    func testPasswordPolicyShortRejected() {
        XCTAssertNotNil(PasswordPolicy.validate("short1!"))
    }

    func testPasswordPolicyMissingDigitRejected() {
        XCTAssertNotNil(PasswordPolicy.validate("noDigitsHere!!"))
    }

    func testPasswordPolicyMissingSymbolRejected() {
        XCTAssertNotNil(PasswordPolicy.validate("NoSymbolsHere1"))
    }

    func testPasswordPolicyStrongAccepted() {
        XCTAssertNil(PasswordPolicy.validate("ValidPass123!"))
    }

    // MARK: - Enrollment and verification

    func testEnrollAndVerifyRoundTrip() throws {
        let (cs, _) = store()
        try cs.enroll(username: "alice", password: "ValidPass123!", user: alice)
        XCTAssertEqual(cs.verify(username: "alice", password: "ValidPass123!"), alice)
    }

    func testVerifyRejectsWrongPassword() throws {
        let (cs, _) = store()
        try cs.enroll(username: "alice", password: "ValidPass123!", user: alice)
        XCTAssertNil(cs.verify(username: "alice", password: "WrongPass123!"))
    }

    func testVerifyUnknownUsernameReturnsNil() {
        let (cs, _) = store()
        XCTAssertNil(cs.verify(username: "ghost", password: "whatever"))
    }

    func testEnrollRejectsWeakPassword() {
        let (cs, _) = store()
        XCTAssertThrowsError(try cs.enroll(username: "alice", password: "short", user: alice)) { err in
            if case .weakPassword = err as? CredentialError { /* expected */ }
            else { XCTFail("expected weakPassword") }
        }
    }

    func testEnrollDuplicateUsernameRejected() throws {
        let (cs, _) = store()
        try cs.enroll(username: "alice", password: "ValidPass123!", user: alice)
        XCTAssertThrowsError(try cs.enroll(username: "alice", password: "AnotherPass123!", user: alice)) { err in
            XCTAssertEqual(err as? CredentialError, .usernameAlreadyEnrolled)
        }
    }

    func testUsernameLookupIsCaseInsensitive() throws {
        let (cs, _) = store()
        try cs.enroll(username: "Alice", password: "ValidPass123!", user: alice)
        XCTAssertEqual(cs.verify(username: "alice", password: "ValidPass123!"), alice)
        XCTAssertEqual(cs.verify(username: "ALICE", password: "ValidPass123!"), alice)
    }

    func testUserLookupByUsername() throws {
        let (cs, _) = store()
        try cs.enroll(username: "alice", password: "ValidPass123!", user: alice)
        XCTAssertEqual(cs.user(forUsername: "alice"), alice)
        XCTAssertNil(cs.user(forUsername: "ghost"))
    }

    func testRemoveUser() throws {
        let (cs, _) = store()
        try cs.enroll(username: "alice", password: "ValidPass123!", user: alice)
        try cs.remove(username: "alice")
        XCTAssertNil(cs.verify(username: "alice", password: "ValidPass123!"))
    }

    func testRemoveMissingUserThrows() {
        let (cs, _) = store()
        XCTAssertThrowsError(try cs.remove(username: "ghost")) { err in
            XCTAssertEqual(err as? CredentialError, .userNotFound)
        }
    }

    // MARK: - Salt / pepper / stability

    func testDifferentUsersHaveDistinctHashesEvenWithSamePassword() throws {
        // Use a mutable salt provider that returns different bytes on each call.
        let kc = InMemoryKeychain()
        var counter: UInt8 = 0
        let cs = KeychainCredentialStore(keychain: kc, saltProvider: {
            counter &+= 1
            return Data(repeating: counter, count: 32)
        })
        try cs.enroll(username: "alice", password: "SamePass123!", user: alice)
        try cs.enroll(username: "bob",   password: "SamePass123!", user: bob)
        let aData = kc.get("railcommerce.credential.alice")!
        let bData = kc.get("railcommerce.credential.bob")!
        let aEntry = try JSONDecoder().decode(StoredCredential.self, from: aData)
        let bEntry = try JSONDecoder().decode(StoredCredential.self, from: bData)
        XCTAssertNotEqual(aEntry.hash, bEntry.hash)
        XCTAssertNotEqual(aEntry.salt, bEntry.salt)
    }

    func testHashStableForSameInputs() {
        let pepper = Data(repeating: 0xaa, count: 32)
        let salt = Data(repeating: 0xbb, count: 32)
        let h1 = KeychainCredentialStore.pbkdf2(password: "x", pepper: pepper, salt: salt, iterations: 1_000)
        let h2 = KeychainCredentialStore.pbkdf2(password: "x", pepper: pepper, salt: salt, iterations: 1_000)
        XCTAssertEqual(h1, h2)
    }

    func testHashChangesWithDifferentPassword() {
        let pepper = Data(repeating: 0xaa, count: 32)
        let salt = Data(repeating: 0xbb, count: 32)
        let h1 = KeychainCredentialStore.pbkdf2(password: "x", pepper: pepper, salt: salt, iterations: 1_000)
        let h2 = KeychainCredentialStore.pbkdf2(password: "y", pepper: pepper, salt: salt, iterations: 1_000)
        XCTAssertNotEqual(h1, h2)
    }

    func testHashChangesWithDifferentSalt() {
        let pepper = Data(repeating: 0xaa, count: 32)
        let h1 = KeychainCredentialStore.pbkdf2(password: "x", pepper: pepper,
                                                salt: Data(repeating: 1, count: 32), iterations: 1_000)
        let h2 = KeychainCredentialStore.pbkdf2(password: "x", pepper: pepper,
                                                salt: Data(repeating: 2, count: 32), iterations: 1_000)
        XCTAssertNotEqual(h1, h2)
    }

    func testHashChangesWithDifferentPepper() {
        let salt = Data(repeating: 0xbb, count: 32)
        let h1 = KeychainCredentialStore.pbkdf2(password: "x", pepper: Data(repeating: 1, count: 32),
                                                salt: salt, iterations: 1_000)
        let h2 = KeychainCredentialStore.pbkdf2(password: "x", pepper: Data(repeating: 2, count: 32),
                                                salt: salt, iterations: 1_000)
        XCTAssertNotEqual(h1, h2)
    }

    func testPepperPersistsAcrossStoreInstances() throws {
        let kc = InMemoryKeychain()
        let cs1 = KeychainCredentialStore(keychain: kc)
        try cs1.enroll(username: "alice", password: "ValidPass123!", user: alice)
        // New credential store instance sharing the same keychain — pepper must match.
        let cs2 = KeychainCredentialStore(keychain: kc)
        XCTAssertEqual(cs2.verify(username: "alice", password: "ValidPass123!"), alice)
    }

    // MARK: - Constant-time equality

    func testConstantTimeEqualMatches() {
        XCTAssertTrue(KeychainCredentialStore.constantTimeEqual(
            Data([1, 2, 3]), Data([1, 2, 3])))
    }

    func testConstantTimeEqualDiffersInContent() {
        XCTAssertFalse(KeychainCredentialStore.constantTimeEqual(
            Data([1, 2, 3]), Data([1, 2, 4])))
    }

    func testConstantTimeEqualDiffersInLength() {
        XCTAssertFalse(KeychainCredentialStore.constantTimeEqual(
            Data([1, 2, 3]), Data([1, 2, 3, 4])))
    }

    // MARK: - Random bytes

    func testRandomBytesReturnsRequestedLength() {
        XCTAssertEqual(KeychainCredentialStore.randomBytes(16).count, 16)
        XCTAssertEqual(KeychainCredentialStore.randomBytes(32).count, 32)
    }
}
