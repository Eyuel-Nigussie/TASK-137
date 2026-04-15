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

        // Browse is available to all roles.
        tabs.append(nav(BrowseViewController(app: app, user: currentUser),
                        title: "Browse", image: "list.bullet"))

        if RolePolicy.can(currentUser.role, .purchase) {
            tabs.append(nav(CartViewController(app: app, user: currentUser),
                            title: "Cart", image: "cart"))
            tabs.append(nav(SeatInventoryViewController(app: app, user: currentUser),
                            title: "Seats", image: "tram.fill"))
            tabs.append(nav(AfterSalesViewController(app: app, user: currentUser),
                            title: "Returns", image: "arrow.uturn.left.circle"))
        }

        if RolePolicy.can(currentUser.role, .processTransaction) {
            tabs.append(nav(SeatInventoryViewController(app: app, user: currentUser),
                            title: "Inventory", image: "tram.fill"))
        }

        if RolePolicy.can(currentUser.role, .draftContent) {
            tabs.append(nav(ContentPublishingViewController(app: app, user: currentUser),
                            title: "Content", image: "doc.text"))
        }

        if RolePolicy.can(currentUser.role, .matchTalent) ||
           RolePolicy.can(currentUser.role, .handleServiceTickets) {
            tabs.append(nav(TalentMatchingViewController(app: app, user: currentUser),
                            title: "Talent", image: "person.3"))
        }

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
