import XCTest
@testable import RailCommerce

final class RolesTests: XCTestCase {
    func testCustomerPermissions() {
        XCTAssertTrue(RolePolicy.can(.customer, .purchase))
        XCTAssertFalse(RolePolicy.can(.customer, .manageUsers))
    }

    func testSalesAgentPermissions() {
        XCTAssertTrue(RolePolicy.can(.salesAgent, .processTransaction))
        XCTAssertTrue(RolePolicy.can(.salesAgent, .manageInventory))
        XCTAssertFalse(RolePolicy.can(.salesAgent, .publishContent))
    }

    func testEditorReviewerSplit() {
        XCTAssertTrue(RolePolicy.can(.contentEditor, .draftContent))
        XCTAssertFalse(RolePolicy.can(.contentEditor, .publishContent))
        XCTAssertTrue(RolePolicy.can(.contentReviewer, .publishContent))
        XCTAssertFalse(RolePolicy.can(.contentReviewer, .draftContent))
    }

    func testCSRPermissions() {
        XCTAssertTrue(RolePolicy.can(.customerService, .handleServiceTickets))
        XCTAssertTrue(RolePolicy.can(.customerService, .sendStaffMessage))
    }

    func testAdministratorHasAll() {
        for permission in Permission.allCases {
            XCTAssertTrue(RolePolicy.can(.administrator, permission), "admin missing \(permission)")
        }
    }

    func testAllRolesAndPermissionsEncodeDecode() throws {
        for role in Role.allCases {
            let data = try JSONEncoder().encode(role)
            let decoded = try JSONDecoder().decode(Role.self, from: data)
            XCTAssertEqual(decoded, role)
        }
        for permission in Permission.allCases {
            let data = try JSONEncoder().encode(permission)
            let decoded = try JSONDecoder().decode(Permission.self, from: data)
            XCTAssertEqual(decoded, permission)
        }
    }

    func testUserRoundTrip() throws {
        let u = User(id: "u1", displayName: "Alice", role: .salesAgent)
        let data = try JSONEncoder().encode(u)
        let decoded = try JSONDecoder().decode(User.self, from: data)
        XCTAssertEqual(decoded, u)
    }
}
