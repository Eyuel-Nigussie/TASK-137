#if canImport(UIKit)
import UIKit
import RailCommerce

/// iPad root container: a two-column split view that lists role-aware tabs in the
/// primary sidebar and renders the selected feature in the secondary. On compact
/// size classes (Slide Over, Split View multitasking on iPhone-sized width) the
/// split view collapses and we fall back to the tab bar controller transparently.
final class MainSplitViewController: UISplitViewController, UISplitViewControllerDelegate {

    private let app: RailCommerce
    private let currentUser: User
    private let tabBar: MainTabBarController

    init(app: RailCommerce, currentUser: User) {
        self.app = app
        self.currentUser = currentUser
        self.tabBar = MainTabBarController(app: app, currentUser: currentUser)
        super.init(style: .doubleColumn)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        preferredDisplayMode = .oneBesideSecondary
        presentsWithGesture = true

        // Primary sidebar: role-aware list of features.
        let sidebar = FeatureSidebarViewController(app: app, currentUser: currentUser) { [weak self] vc in
            self?.showFeature(vc)
        }
        setViewController(UINavigationController(rootViewController: sidebar), for: .primary)

        // Secondary: start on Browse (always available to every role).
        let initial = BrowseViewController(app: app, user: currentUser)
        setViewController(UINavigationController(rootViewController: initial), for: .secondary)

        // Compact: fall back to the tab bar.
        setViewController(tabBar, for: .compact)
    }

    private func showFeature(_ vc: UIViewController) {
        setViewController(UINavigationController(rootViewController: vc), for: .secondary)
        show(.secondary)
    }

    // MARK: - UISplitViewControllerDelegate

    func splitViewController(_ svc: UISplitViewController,
                             topColumnForCollapsingToProposedTopColumn proposed: UISplitViewController.Column) -> UISplitViewController.Column {
        .compact
    }
}

/// Sidebar for the iPad split view. Mirrors the role-aware tabs from
/// `MainTabBarController` as a single-column table.
final class FeatureSidebarViewController: UITableViewController {
    struct Feature {
        let title: String
        let systemImage: String
        let factory: () -> UIViewController
    }

    private let features: [Feature]
    private let onSelect: (UIViewController) -> Void

    init(app: RailCommerce, currentUser: User, onSelect: @escaping (UIViewController) -> Void) {
        var features: [Feature] = [
            Feature(title: "Browse", systemImage: "list.bullet",
                    factory: { BrowseViewController(app: app, user: currentUser) }),
            Feature(title: "Advisories", systemImage: "newspaper",
                    factory: { ContentBrowseViewController(app: app, user: currentUser) })
        ]

        if RolePolicy.can(currentUser.role, .purchase) {
            features.append(Feature(title: "Cart", systemImage: "cart",
                                    factory: { CartViewController(app: app, user: currentUser) }))
            features.append(Feature(title: "Seats", systemImage: "tram.fill",
                                    factory: { SeatInventoryViewController(app: app, user: currentUser) }))
            features.append(Feature(title: "Returns", systemImage: "arrow.uturn.left.circle",
                                    factory: { AfterSalesViewController(app: app, user: currentUser) }))
        }
        if RolePolicy.can(currentUser.role, .processTransaction) {
            features.append(Feature(title: "Inventory", systemImage: "tram.fill",
                                    factory: { SeatInventoryViewController(app: app, user: currentUser) }))
        }
        if RolePolicy.can(currentUser.role, .draftContent) || RolePolicy.can(currentUser.role, .publishContent) {
            features.append(Feature(title: "Content", systemImage: "doc.text",
                                    factory: { ContentPublishingViewController(app: app, user: currentUser) }))
        }
        if RolePolicy.can(currentUser.role, .matchTalent) {
            features.append(Feature(title: "Talent", systemImage: "person.3",
                                    factory: { TalentMatchingViewController(app: app, user: currentUser) }))
        }
        features.append(Feature(title: "Membership", systemImage: "star.circle",
                                factory: { MembershipViewController(app: app, user: currentUser) }))
        features.append(Feature(title: "Messages", systemImage: "bubble.left.and.bubble.right",
                                factory: { MessagingViewController(app: app, user: currentUser) }))

        self.features = features
        self.onSelect = onSelect
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "RailCommerce"
        navigationItem.largeTitleDisplayMode = .automatic
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "feature")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { features.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "feature", for: indexPath)
        let feature = features[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = feature.title
        config.image = UIImage(systemName: feature.systemImage)
        cell.contentConfiguration = config
        cell.accessibilityLabel = feature.title
        cell.accessibilityHint = "Opens the \(feature.title) feature"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect(features[indexPath.row].factory())
    }
}
#endif
