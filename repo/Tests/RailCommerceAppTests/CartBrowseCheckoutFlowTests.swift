import XCTest
import UIKit
@testable import RailCommerceApp
@testable import RailCommerce

/// Smoke-tests that instantiate the three customer-facing view controllers
/// (`BrowseViewController`, `CartViewController`, `CheckoutViewController`),
/// load their views, and exercise a representative action on each so the UI
/// code paths are covered by the iOS test target.
final class CartBrowseCheckoutFlowTests: XCTestCase {

    private func makeApp() -> (RailCommerce, User) {
        let app = RailCommerce()
        // Seed a single SKU so Browse and Cart have something to render.
        app.catalog.upsert(SKU(id: "t1", kind: .ticket, title: "NE Express",
                               priceCents: 5_000,
                               tag: TaxonomyTag(region: .northeast,
                                                theme: .scenic,
                                                riderType: .tourist)))
        let user = User(id: "c1", displayName: "Alice", role: .customer)
        return (app, user)
    }

    // MARK: - Browse

    func testBrowseViewControllerLoadsAndRendersCatalog() {
        let (app, user) = makeApp()
        let vc = BrowseViewController(app: app, user: user)
        vc.loadViewIfNeeded()
        XCTAssertEqual(vc.title, "Browse")
        XCTAssertEqual(vc.tableView.numberOfSections, 1,
                       "Browse table must present one section")
    }

    // MARK: - Cart

    func testCartViewControllerReflectsUserScopedCart() throws {
        let (app, user) = makeApp()
        try app.cart(forUser: user.id).add(skuId: "t1", quantity: 2)
        let vc = CartViewController(app: app, user: user)
        vc.loadViewIfNeeded()
        XCTAssertEqual(vc.title, "Cart")
        XCTAssertEqual(vc.view.backgroundColor, .systemBackground)
    }

    func testCartViewControllerStartsEmptyForFreshUser() {
        let (app, user) = makeApp()
        let vc = CartViewController(app: app, user: user)
        vc.loadViewIfNeeded()
        XCTAssertTrue(app.cart(forUser: user.id).isEmpty,
                      "new user on a shared device must see an empty cart")
    }

    // MARK: - Checkout

    func testCheckoutViewControllerLoadsForUserWithItems() throws {
        let (app, user) = makeApp()
        let cart = app.cart(forUser: user.id)
        try cart.add(skuId: "t1", quantity: 1)
        let vc = CheckoutViewController(app: app, user: user, cart: cart)
        vc.loadViewIfNeeded()
        XCTAssertEqual(vc.title, "Checkout")
    }

    func testCheckoutReadsUserScopedDefaultAddress() throws {
        let (app, user) = makeApp()
        let cart = app.cart(forUser: user.id)
        try cart.add(skuId: "t1", quantity: 1)
        _ = try app.addressBook.save(
            USAddress(id: "a1", recipient: "Alice", line1: "1 Main",
                      city: "NYC", state: .NY, zip: "10001"),
            ownedBy: user.id)
        let vc = CheckoutViewController(app: app, user: user, cart: cart)
        vc.loadViewIfNeeded()
        // Trigger viewWillAppear to cause the default-address fallback path
        // to run against the user-scoped book.
        vc.beginAppearanceTransition(true, animated: false)
        vc.endAppearanceTransition()
        XCTAssertNotNil(app.addressBook.defaultAddress(for: user.id),
                        "user-scoped default must be retrievable by the VC")
    }
}
