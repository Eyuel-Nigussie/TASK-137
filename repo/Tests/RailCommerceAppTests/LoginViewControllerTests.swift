import XCTest
import UIKit
@testable import RailCommerceApp
@testable import RailCommerce

/// Smoke tests that drive `LoginViewController` through its key state
/// transitions without a real biometric device. Loads the view, triggers the
/// sign-in path, and verifies the bootstrap enrollment affordance.
final class LoginViewControllerTests: XCTestCase {

    private func makeVC(credentials: CredentialStore) -> LoginViewController {
        let app = RailCommerce()
        let vc = LoginViewController(app: app, credentials: credentials)
        vc.loadViewIfNeeded()
        return vc
    }

    // MARK: - First-install bootstrap affordance

    func testEnrollButtonVisibleOnEmptyCredentialStore() {
        let keychain = InMemoryKeychain()
        let store = KeychainCredentialStore(keychain: keychain)
        XCTAssertFalse(store.hasAnyCredentials())
        let vc = makeVC(credentials: store)
        // Reach into the view hierarchy and assert the enrollment button is visible.
        let enrollButton = vc.view.firstDescendant(ofType: UIButton.self) { btn in
            btn.title(for: .normal)?.contains("Create Administrator") ?? false
        }
        XCTAssertNotNil(enrollButton,
                        "bootstrap enrollment button must be present when no credentials exist")
        XCTAssertEqual(enrollButton?.isHidden, false,
                       "bootstrap enrollment button must be visible on empty credential store")
    }

    func testEnrollButtonHiddenWhenCredentialsExist() throws {
        let keychain = InMemoryKeychain()
        let store = KeychainCredentialStore(keychain: keychain)
        try store.enroll(username: "admin", password: "AdminPass!2024",
                         user: User(id: "a1", displayName: "A", role: .administrator))
        let vc = makeVC(credentials: store)
        let enrollButton = vc.view.firstDescendant(ofType: UIButton.self) { btn in
            btn.title(for: .normal)?.contains("Create Administrator") ?? false
        }
        XCTAssertEqual(enrollButton?.isHidden, true,
                       "enrollment button must be hidden once a credential is on file")
    }

    // MARK: - View-lifecycle smoke

    func testViewLoadsWithoutCrashing() {
        let keychain = InMemoryKeychain()
        let store = KeychainCredentialStore(keychain: keychain)
        let vc = makeVC(credentials: store)
        XCTAssertNotNil(vc.view)
        XCTAssertEqual(vc.view.backgroundColor, .systemBackground)
    }
}

// MARK: - Test helper

extension UIView {
    /// Depth-first search for the first descendant of the given type matching
    /// the optional predicate. Keeps the LoginViewController tests concise
    /// without pulling in a whole test DSL.
    fileprivate func firstDescendant<T: UIView>(
        ofType type: T.Type,
        where predicate: (T) -> Bool = { _ in true }
    ) -> T? {
        if let self = self as? T, predicate(self) { return self }
        for sub in subviews {
            if let match = sub.firstDescendant(ofType: type, where: predicate) {
                return match
            }
        }
        return nil
    }
}
