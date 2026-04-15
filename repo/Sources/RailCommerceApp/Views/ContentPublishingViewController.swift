#if canImport(UIKit)
import UIKit
import RailCommerce

/// Content draft creation and publishing workflow for editors and reviewers.
final class ContentPublishingViewController: UITableViewController {

    private let app: RailCommerce
    private let user: User

    init(app: RailCommerce, user: User) {
        self.app = app
        self.user = user
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Content"
        if RolePolicy.can(user.role, .draftContent) {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .add, target: self, action: #selector(newDraft))
        }
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "item")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    // MARK: - UITableViewDataSource

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        app.publishing.items(publishedOnly: false).count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "item", for: indexPath)
        let item = app.publishing.items(publishedOnly: false)[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = item.title
        config.secondaryText = item.status.rawValue.capitalized
        cell.contentConfiguration = config
        return cell
    }

    // MARK: - Reviewer swipe-actions

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard RolePolicy.can(user.role, .publishContent) else { return nil }
        let item = app.publishing.items(publishedOnly: false)[indexPath.row]
        guard item.status == .inReview else { return nil }

        let approve = UIContextualAction(style: .normal, title: "Approve") { [weak self] _, _, done in
            guard let self else { return done(false) }
            try? self.app.publishing.approve(id: item.id, reviewer: self.user)
            tableView.reloadData()
            done(true)
        }
        approve.backgroundColor = .systemGreen

        let reject = UIContextualAction(style: .destructive, title: "Reject") { [weak self] _, _, done in
            guard let self else { return done(false) }
            try? self.app.publishing.reject(id: item.id, reviewer: self.user)
            tableView.reloadData()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [approve, reject])
    }

    // MARK: - Editor actions

    @objc private func newDraft() {
        let alert = UIAlertController(title: "New Draft", message: "Enter title",
                                      preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Content title" }
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self, let title = alert.textFields?.first?.text, !title.isEmpty else { return }
            do {
                _ = try self.app.publishing.createDraft(
                    id: UUID().uuidString,
                    kind: .travelAdvisory,
                    title: title,
                    tag: TaxonomyTag(),
                    body: "Draft content.",
                    editorId: self.user.id,
                    actingUser: self.user
                )
                self.tableView.reloadData()
            } catch {
                let err = UIAlertController(title: "Error",
                                            message: error.localizedDescription,
                                            preferredStyle: .alert)
                err.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(err, animated: true)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}
#endif
