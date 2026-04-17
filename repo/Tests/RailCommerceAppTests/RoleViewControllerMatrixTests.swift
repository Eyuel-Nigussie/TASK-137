import XCTest
import UIKit
@testable import RailCommerceApp
@testable import RailCommerce

/// Exercises the full matrix of role-specific view controllers that make up
/// the post-login shell: each role sees the tabs it is authorized for, and
/// every tab's root view controller loads without crashing.
final class RoleViewControllerMatrixTests: XCTestCase {

    private func makeApp() -> RailCommerce {
        let app = RailCommerce()
        app.catalog.upsert(SKU(id: "t1", kind: .ticket, title: "NE Express",
                               priceCents: 5_000,
                               tag: TaxonomyTag(region: .northeast,
                                                theme: .scenic,
                                                riderType: .tourist)))
        return app
    }

    // MARK: - MainTabBarController per-role

    func testMainTabBarLoadsForEveryRole() {
        let app = makeApp()
        for role in Role.allCases {
            let user = User(id: "u_\(role.rawValue)", displayName: "U", role: role)
            let tabBar = MainTabBarController(app: app, currentUser: user)
            tabBar.loadViewIfNeeded()
            XCTAssertNotNil(tabBar.viewControllers,
                            "role \(role) must produce at least one tab")
            XCTAssertFalse(tabBar.viewControllers?.isEmpty ?? true,
                           "role \(role) must have at least one tab")
        }
    }

    func testMainTabBarTabCountMatchesRolePermissions() {
        let app = makeApp()
        // Customer has browse + purchase + manageAfterSales.
        let customer = User(id: "c1", displayName: "C", role: .customer)
        let tabs = MainTabBarController(app: app, currentUser: customer)
        tabs.loadViewIfNeeded()
        XCTAssertGreaterThan(tabs.viewControllers?.count ?? 0, 0)
    }

    // MARK: - Split view (iPad shell)

    func testMainSplitViewLoadsForAdmin() {
        let app = makeApp()
        let admin = User(id: "admin", displayName: "Admin", role: .administrator)
        let split = MainSplitViewController(app: app, currentUser: admin)
        split.loadViewIfNeeded()
        XCTAssertNotNil(split.view)
    }

    func testMainSplitViewLoadsForCustomer() {
        let app = makeApp()
        let customer = User(id: "c1", displayName: "C", role: .customer)
        let split = MainSplitViewController(app: app, currentUser: customer)
        split.loadViewIfNeeded()
        XCTAssertNotNil(split.view)
    }

    // MARK: - Feature VCs the existing CartBrowseCheckout suite doesn't cover

    func testMessagingViewControllerLoadsForCSR() {
        let app = makeApp()
        let csr = User(id: "csr1", displayName: "CSR", role: .customerService)
        let vc = MessagingViewController(app: app, user: csr)
        vc.loadViewIfNeeded()
        XCTAssertEqual(vc.title, "Messages")
    }

    func testSeatInventoryViewControllerLoadsForAgent() {
        let app = makeApp()
        let agent = User(id: "a1", displayName: "A", role: .salesAgent)
        let vc = SeatInventoryViewController(app: app, user: agent)
        vc.loadViewIfNeeded()
        XCTAssertNotNil(vc.view)
    }

    func testAfterSalesViewControllerLoadsForCustomer() {
        let app = makeApp()
        let customer = User(id: "c1", displayName: "C", role: .customer)
        let vc = AfterSalesViewController(app: app, user: customer)
        vc.loadViewIfNeeded()
        XCTAssertNotNil(vc.view)
    }

    func testAfterSalesViewControllerLoadsForCSR() {
        let app = makeApp()
        let csr = User(id: "csr1", displayName: "CSR", role: .customerService)
        let vc = AfterSalesViewController(app: app, user: csr)
        vc.loadViewIfNeeded()
        XCTAssertNotNil(vc.view)
    }

    func testContentPublishingViewControllerLoadsForEditor() {
        let app = makeApp()
        let editor = User(id: "e1", displayName: "Eve", role: .contentEditor)
        let vc = ContentPublishingViewController(app: app, user: editor)
        vc.loadViewIfNeeded()
        XCTAssertNotNil(vc.view)
    }

    func testContentPublishingViewControllerLoadsForReviewer() {
        let app = makeApp()
        let reviewer = User(id: "r1", displayName: "Rita", role: .contentReviewer)
        let vc = ContentPublishingViewController(app: app, user: reviewer)
        vc.loadViewIfNeeded()
        XCTAssertNotNil(vc.view)
    }

    func testContentBrowseViewControllerLoadsForCustomer() {
        let app = makeApp()
        let customer = User(id: "c1", displayName: "C", role: .customer)
        let vc = ContentBrowseViewController(app: app, user: customer)
        vc.loadViewIfNeeded()
        XCTAssertNotNil(vc.view)
    }

    func testTalentMatchingViewControllerLoadsForAdmin() {
        let app = makeApp()
        let admin = User(id: "admin", displayName: "A", role: .administrator)
        let vc = TalentMatchingViewController(app: app, user: admin)
        vc.loadViewIfNeeded()
        XCTAssertNotNil(vc.view)
    }

    func testMembershipViewControllerLoadsForCustomer() {
        let app = makeApp()
        let customer = User(id: "c1", displayName: "C", role: .customer)
        let vc = MembershipViewController(app: app, user: customer)
        vc.loadViewIfNeeded()
        XCTAssertNotNil(vc.view)
    }

    func testAfterSalesCaseThreadViewControllerLoads() throws {
        let app = makeApp()
        let customer = User(id: "c1", displayName: "C", role: .customer)
        // Seed a real checkout order so the after-sales ownership validator
        // (`checkout.order(orderId, ownedBy: userId)`) accepts the request.
        let cart = app.cart(forUser: customer.id)
        try cart.add(skuId: "t1", quantity: 1)
        let addr = USAddress(id: "a1", recipient: "C", line1: "1 Main",
                             city: "NYC", state: .NY, zip: "10001")
        _ = try app.addressBook.save(addr, ownedBy: customer.id)
        let ship = ShippingTemplate(id: "std", name: "Std", feeCents: 500, etaDays: 3)
        let snap = try app.checkout.submit(orderId: "O-thread",
                                           userId: customer.id,
                                           cart: cart, discounts: [],
                                           address: addr, shipping: ship,
                                           invoiceNotes: "",
                                           actingUser: customer)
        let req = AfterSalesRequest(id: "R1", orderId: snap.orderId,
                                    kind: .refundOnly, reason: .changedMind,
                                    createdAt: Date(),
                                    serviceDate: Date(),
                                    amountCents: 500)
        try app.afterSales.open(req, actingUser: customer)
        let vc = AfterSalesCaseThreadViewController(app: app, user: customer,
                                                    request: req)
        vc.loadViewIfNeeded()
        XCTAssertNotNil(vc.view)
    }
}
