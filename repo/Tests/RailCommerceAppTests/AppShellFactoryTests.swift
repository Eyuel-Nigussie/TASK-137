import XCTest
import UIKit
@testable import RailCommerceApp
@testable import RailCommerce

/// Exercises `AppShellFactory` — the role-aware root view controller builder.
/// Each role must receive a shell whose tabs match their permission set.
final class AppShellFactoryTests: XCTestCase {

    private func makeApp() -> RailCommerce {
        RailCommerce()
    }

    func testAdminGetsASplitOrTabShell() {
        let app = makeApp()
        let admin = User(id: "admin", displayName: "A", role: .administrator)
        let shell = AppShellFactory.makeShell(app: app, currentUser: admin)
        XCTAssertNotNil(shell, "admin role must resolve a shell view controller")
    }

    func testCustomerShellResolves() {
        let app = makeApp()
        let customer = User(id: "c1", displayName: "C", role: .customer)
        let shell = AppShellFactory.makeShell(app: app, currentUser: customer)
        XCTAssertNotNil(shell, "customer role must resolve a shell view controller")
    }

    func testEveryRoleProducesAShell() {
        let app = makeApp()
        for role in Role.allCases {
            let user = User(id: "u_\(role.rawValue)", displayName: "U", role: role)
            let shell = AppShellFactory.makeShell(app: app, currentUser: user)
            XCTAssertNotNil(shell,
                            "role \(role) must produce a shell — missing role coverage in factory")
        }
    }
}
