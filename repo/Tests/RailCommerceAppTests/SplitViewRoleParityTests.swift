import XCTest
import UIKit
@testable import RailCommerceApp
@testable import RailCommerce

/// Audit report-1 Blocker closure: the iPad split-view shell must not be a
/// stricter shell than the iPhone tab-bar shell. Sales Agents (who have
/// `.processTransaction` but not `.purchase`) must see Cart / Seats / Returns
/// on iPad too — otherwise the prompt's "iPhone + iPad" requirement is not
/// satisfied for the Sales Agent workflow.
final class SplitViewRoleParityTests: XCTestCase {

    private func makeApp() -> RailCommerce {
        let app = RailCommerce()
        app.catalog.upsert(SKU(id: "t1", kind: .ticket, title: "NE Express",
                               priceCents: 5_000,
                               tag: TaxonomyTag(region: .northeast,
                                                theme: .scenic,
                                                riderType: .tourist)))
        return app
    }

    /// Walks the sidebar's cells and returns the visible feature titles so
    /// tests can assert exact parity with the tab-bar shell.
    private func sidebarTitles(for user: User) -> [String] {
        let app = makeApp()
        let sidebar = FeatureSidebarViewController(app: app, currentUser: user,
                                                   onSelect: { _ in })
        sidebar.loadViewIfNeeded()
        let rowCount = sidebar.tableView(sidebar.tableView, numberOfRowsInSection: 0)
        var titles: [String] = []
        for row in 0..<rowCount {
            let cell = sidebar.tableView(sidebar.tableView,
                                         cellForRowAt: IndexPath(row: row, section: 0))
            if let text = cell.contentConfiguration as? UIListContentConfiguration,
               let title = text.text {
                titles.append(title)
            }
        }
        return titles
    }

    // MARK: - Sales Agent parity on iPad

    /// Covers: audit report-1 Blocker — Sales Agent transaction flow on iPad.
    /// Sidebar MUST include Cart, Seats, and Returns for `.salesAgent` so an
    /// on-behalf-of-customer sale is reachable from the iPad shell.
    func testSalesAgentSidebarIncludesTransactionFeaturesOnSplitShell() {
        let agent = User(id: "a1", displayName: "Sam Agent", role: .salesAgent)
        let titles = sidebarTitles(for: agent)
        XCTAssertTrue(titles.contains("Cart"),
                      "Sales Agent must see 'Cart' on the iPad split-view sidebar (audit report-1 Blocker)")
        XCTAssertTrue(titles.contains("Seats"),
                      "Sales Agent must see 'Seats' on the iPad split-view sidebar")
        XCTAssertTrue(titles.contains("Returns"),
                      "Sales Agent must see 'Returns' on the iPad split-view sidebar")
    }

    // MARK: - Customer parity — baseline

    func testCustomerSidebarIncludesTransactionFeatures() {
        let customer = User(id: "c1", displayName: "C", role: .customer)
        let titles = sidebarTitles(for: customer)
        XCTAssertTrue(titles.contains("Cart"))
        XCTAssertTrue(titles.contains("Seats"))
        XCTAssertTrue(titles.contains("Returns"))
    }

    // MARK: - Content Editor must NOT see transaction features

    func testContentEditorSidebarHidesTransactionFeatures() {
        let editor = User(id: "e1", displayName: "Ed", role: .contentEditor)
        let titles = sidebarTitles(for: editor)
        XCTAssertFalse(titles.contains("Cart"),
                       "Content Editor has neither .purchase nor .processTransaction; Cart must be hidden")
        XCTAssertFalse(titles.contains("Seats"),
                       "Content Editor must not see Seats in the iPad sidebar")
        XCTAssertFalse(titles.contains("Returns"),
                       "Content Editor must not see Returns in the iPad sidebar")
        XCTAssertTrue(titles.contains("Content"),
                      "Content Editor must see the Content authoring feature")
    }

    // MARK: - Admin sees everything

    func testAdministratorSidebarContainsEveryFeature() {
        let admin = User(id: "admin", displayName: "Admin", role: .administrator)
        let titles = sidebarTitles(for: admin)
        for required in ["Cart", "Seats", "Returns", "Content", "Talent",
                         "Membership", "Messages", "Browse", "Advisories"] {
            XCTAssertTrue(titles.contains(required),
                          "Administrator sidebar must include \(required)")
        }
    }

    // MARK: - Tab-bar parity — regression guard

    /// The tab bar and split-view sidebar must expose the same transaction
    /// features for a given role. If a future refactor diverges them, this
    /// test fails loudly — preventing a repeat of the audit report-1 Blocker.
    func testTabBarAndSidebarExposeSameTransactionFeaturesForSalesAgent() {
        let agent = User(id: "a1", displayName: "Sam Agent", role: .salesAgent)
        let sidebar = Set(sidebarTitles(for: agent))

        let app = makeApp()
        let tabBar = MainTabBarController(app: app, currentUser: agent)
        tabBar.loadViewIfNeeded()
        let tabTitles = Set((tabBar.viewControllers ?? []).compactMap { $0.tabBarItem.title })

        for required in ["Cart", "Seats", "Returns"] {
            XCTAssertEqual(tabTitles.contains(required), sidebar.contains(required),
                           "Tab-bar and split-view must agree on '\(required)' for Sales Agent")
        }
    }
}
