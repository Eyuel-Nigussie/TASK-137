#if canImport(UIKit)
import UIKit
import RailCommerce

/// Root navigation container. Tabs are built from the current user's role permissions.
final class MainTabBarController: UITabBarController {

    private let app: RailCommerce
    let currentUser: User

    init(app: RailCommerce, currentUser: User) {
        self.app = app
        self.currentUser = currentUser
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        viewControllers = buildTabs()
    }

    // MARK: - Tab construction

    private func buildTabs() -> [UIViewController] {
        var tabs: [UIViewController] = []

        // Browse (catalog) is available to all roles.
        tabs.append(nav(BrowseViewController(app: app, user: currentUser),
                        title: "Browse", image: "list.bullet"))

        // Published content (advisories/offers) browsable by taxonomy — all roles.
        tabs.append(nav(ContentBrowseViewController(app: app, user: currentUser),
                        title: "Advisories", image: "newspaper"))

        // Sales tabs (Cart, Seats, Returns) are shown to anyone who can
        // execute a transaction — customers via `.purchase` AND sales agents
        // via `.processTransaction` (on-behalf-of sales). This satisfies the
        // prompt's "Sales Agent performs ticket/merchandise sales" flow
        // directly in the UI.
        let canTransact = RolePolicy.can(currentUser.role, .purchase)
                        || RolePolicy.can(currentUser.role, .processTransaction)
        if canTransact {
            tabs.append(nav(CartViewController(app: app, user: currentUser),
                            title: "Cart", image: "cart"))
            tabs.append(nav(SeatInventoryViewController(app: app, user: currentUser),
                            title: "Seats", image: "tram.fill"))
            tabs.append(nav(AfterSalesViewController(app: app, user: currentUser),
                            title: "Returns", image: "arrow.uturn.left.circle"))
        }

        // Editors draft content; reviewers approve/reject it — both need the tab.
        if RolePolicy.can(currentUser.role, .draftContent) ||
           RolePolicy.can(currentUser.role, .publishContent) {
            tabs.append(nav(ContentPublishingViewController(app: app, user: currentUser),
                            title: "Content", image: "doc.text"))
        }

        // Only roles with explicit matchTalent permission (admin) access talent search.
        // CSR uses handleServiceTickets — not matchTalent — so they would hit a permission
        // error; the tab is hidden for them.
        if RolePolicy.can(currentUser.role, .matchTalent) {
            tabs.append(nav(TalentMatchingViewController(app: app, user: currentUser),
                            title: "Talent", image: "person.3"))
        }

        // Membership marketing — available to all (customers enroll, admins manage).
        tabs.append(nav(MembershipViewController(app: app, user: currentUser),
                        title: "Membership", image: "star.circle"))

        // Messaging available to all.
        tabs.append(nav(MessagingViewController(app: app, user: currentUser),
                        title: "Messages", image: "bubble.left.and.bubble.right"))

        return tabs
    }

    private func nav(_ vc: UIViewController, title: String, image: String) -> UINavigationController {
        vc.title = title
        let nav = UINavigationController(rootViewController: vc)
        nav.tabBarItem = UITabBarItem(title: title,
                                     image: UIImage(systemName: image),
                                     selectedImage: nil)
        return nav
    }
}
#endif
