import XCTest
@testable import RailCommerce

final class BiometricAuthTests: XCTestCase {

    func testFakeBiometricAuthAvailableAndSucceeds() {
        let auth = FakeBiometricAuth(available: true, succeeds: true)
        XCTAssertTrue(auth.isAvailable)
        var result: Bool?
        auth.authenticate(reason: "test") { result = $0 }
        XCTAssertEqual(result, true)
    }

    func testFakeBiometricAuthUnavailableAndFails() {
        let auth = FakeBiometricAuth(available: false, succeeds: false)
        XCTAssertFalse(auth.isAvailable)
        var result: Bool?
        auth.authenticate(reason: "test") { result = $0 }
        XCTAssertEqual(result, false)
    }

    func testFakeBiometricAuthDefaultsToAvailableAndSucceeds() {
        let auth = FakeBiometricAuth()
        XCTAssertTrue(auth.isAvailable)
        var result: Bool?
        auth.authenticate(reason: "test") { result = $0 }
        XCTAssertEqual(result, true)
    }

    func testFakeBiometricAuthAvailabilityCanBeToggled() {
        let auth = FakeBiometricAuth(available: true, succeeds: true)
        XCTAssertTrue(auth.isAvailable)
        auth.isAvailable = false
        XCTAssertFalse(auth.isAvailable)
    }
}
