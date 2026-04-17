import XCTest
@testable import RailCommerce

/// Security-regression tests for the biometric-to-account binding.
///
/// These tests close the shared-device account-takeover flaw: a device-owner's
/// biometric must only authenticate the account that most recently succeeded
/// at the password path — not any arbitrary account typed into the login field.
final class BiometricBoundAccountTests: XCTestCase {

    private let alice = User(id: "alice", displayName: "Alice", role: .customer)
    private let bob = User(id: "bob", displayName: "Bob", role: .customer)

    func testCurrentIsNilBeforeAnyBinding() {
        let keychain = InMemoryKeychain()
        XCTAssertNil(BiometricBoundAccount.current(in: keychain))
    }

    func testBindAndReadBack() {
        let keychain = InMemoryKeychain()
        BiometricBoundAccount.bind("Alice", in: keychain)
        XCTAssertEqual(BiometricBoundAccount.current(in: keychain), "alice")
    }

    func testBindTrimsAndLowercases() {
        let keychain = InMemoryKeychain()
        BiometricBoundAccount.bind("  BoB  ", in: keychain)
        XCTAssertEqual(BiometricBoundAccount.current(in: keychain), "bob")
    }

    func testBindIgnoresEmptyUsername() {
        let keychain = InMemoryKeychain()
        BiometricBoundAccount.bind("   ", in: keychain)
        XCTAssertNil(BiometricBoundAccount.current(in: keychain))
    }

    func testClearRemovesBinding() {
        let keychain = InMemoryKeychain()
        BiometricBoundAccount.bind("alice", in: keychain)
        BiometricBoundAccount.clear(in: keychain)
        XCTAssertNil(BiometricBoundAccount.current(in: keychain))
    }

    func testRebindOverridesPrevious() {
        let keychain = InMemoryKeychain()
        BiometricBoundAccount.bind("alice", in: keychain)
        BiometricBoundAccount.bind("bob", in: keychain)
        XCTAssertEqual(BiometricBoundAccount.current(in: keychain), "bob")
    }

    // MARK: - resolveUnlock

    func testResolveUnlockReturnsNilWhenNoBinding() {
        let keychain = InMemoryKeychain()
        let user = BiometricBoundAccount.resolveUnlock(
            typedUsername: "alice",
            keychain: keychain,
            credentialLookup: { _ in self.alice }
        )
        XCTAssertNil(user, "Biometric unlock must fail when no account has been bound yet")
    }

    func testResolveUnlockReturnsBoundUserWhenFieldEmpty() {
        let keychain = InMemoryKeychain()
        BiometricBoundAccount.bind("alice", in: keychain)
        let user = BiometricBoundAccount.resolveUnlock(
            typedUsername: "",
            keychain: keychain,
            credentialLookup: { username in username == "alice" ? self.alice : nil }
        )
        XCTAssertEqual(user?.id, "alice")
    }

    func testResolveUnlockReturnsBoundUserWhenTypedMatches() {
        let keychain = InMemoryKeychain()
        BiometricBoundAccount.bind("alice", in: keychain)
        let user = BiometricBoundAccount.resolveUnlock(
            typedUsername: "ALICE",
            keychain: keychain,
            credentialLookup: { username in username == "alice" ? self.alice : nil }
        )
        XCTAssertEqual(user?.id, "alice", "Match should be case-insensitive")
    }

    /// Regression: the reported vulnerability — device biometric success plus
    /// a different typed username must NOT authenticate that other account.
    func testResolveUnlockRejectsDifferentTypedUsername() {
        let keychain = InMemoryKeychain()
        BiometricBoundAccount.bind("alice", in: keychain)
        let user = BiometricBoundAccount.resolveUnlock(
            typedUsername: "bob",
            keychain: keychain,
            credentialLookup: { username in
                username == "alice" ? self.alice : (username == "bob" ? self.bob : nil)
            }
        )
        XCTAssertNil(user, "Biometric must not authenticate into an account different from the bound one")
    }

    func testResolveUnlockReturnsNilWhenBoundAccountNoLongerEnrolled() {
        let keychain = InMemoryKeychain()
        BiometricBoundAccount.bind("alice", in: keychain)
        let user = BiometricBoundAccount.resolveUnlock(
            typedUsername: "",
            keychain: keychain,
            credentialLookup: { _ in nil }
        )
        XCTAssertNil(user)
    }
}
