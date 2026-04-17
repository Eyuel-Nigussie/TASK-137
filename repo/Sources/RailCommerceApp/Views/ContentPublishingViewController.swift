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
        app.publishing.itemsVisible(to: user).count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "item", for: indexPath)
        let item = app.publishing.itemsVisible(to: user)[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = item.title
        config.secondaryText = item.status.rawValue.capitalized
        cell.contentConfiguration = config
        return cell
    }

    // MARK: - Row tap → state-aware action sheet

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = app.publishing.itemsVisible(to: user)[indexPath.row]
        presentActionsSheet(for: item)
    }

    /// Offers the actions valid for the item's current state and the user's role.
    /// - Editor (`.draftContent`) on `.draft` / `.rejected`: submit for review.
    /// - Reviewer (`.publishContent`) on `.inReview`: approve / reject / schedule.
    /// - Editor or reviewer on `.published` / `.scheduled`: rollback (if history).
    private func presentActionsSheet(for item: ContentItem) {
        let sheet = UIAlertController(title: item.title,
                                      message: "Status: \(item.status.rawValue.capitalized)",
                                      preferredStyle: .actionSheet)

        let canDraft = RolePolicy.can(user.role, .draftContent)
        let canPublish = RolePolicy.can(user.role, .publishContent)

        // Submit-for-review (editor only, on draft/rejected)
        if canDraft && (item.status == .draft || item.status == .rejected) {
            sheet.addAction(UIAlertAction(title: "Submit for Review", style: .default) { [weak self] _ in
                self?.trySubmitForReview(item)
            })
        }
        // Approve / Reject / Schedule (reviewer, on inReview)
        if canPublish && item.status == .inReview {
            sheet.addAction(UIAlertAction(title: "Approve & Publish", style: .default) { [weak self] _ in
                self?.tryAction { try self?.app.publishing.approve(id: item.id, reviewer: self!.user) }
            })
            sheet.addAction(UIAlertAction(title: "Reject", style: .destructive) { [weak self] _ in
                self?.tryAction { try self?.app.publishing.reject(id: item.id, reviewer: self!.user) }
            })
            sheet.addAction(UIAlertAction(title: "Schedule Publish...", style: .default) { [weak self] _ in
                self?.presentSchedulePicker(for: item)
            })
        }
        // Rollback (reviewer/editor, on published/scheduled/rolledBack with history)
        if (canDraft || canPublish) && item.versions.count >= 2 {
            sheet.addAction(UIAlertAction(title: "Rollback to Previous Version", style: .destructive) { [weak self] _ in
                self?.tryAction { try self?.app.publishing.rollback(id: item.id, actingUser: self!.user) }
            })
        }

        sheet.addAction(UIAlertAction(title: "Close", style: .cancel))
        if sheet.actions.count == 1 {
            // Only "Close" available — nothing to do for this user/state combo.
            return
        }
        present(sheet, animated: true)
    }

    private func trySubmitForReview(_ item: ContentItem) {
        tryAction { try self.app.publishing.submitForReview(id: item.id, actingUser: self.user) }
    }

    /// Presents a picker offering a few preset publish-time offsets and submits
    /// a schedule request via `ContentPublishingService.schedule`.
    private func presentSchedulePicker(for item: ContentItem) {
        let sheet = UIAlertController(title: "Schedule Publish",
                                      message: "When should this item go live?",
                                      preferredStyle: .actionSheet)
        let choices: [(String, TimeInterval)] = [
            ("In 1 hour", 60 * 60),
            ("In 4 hours", 4 * 60 * 60),
            ("Tomorrow morning", 18 * 60 * 60)
        ]
        for (title, offset) in choices {
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self else { return }
                let when = Date().addingTimeInterval(offset)
                self.tryAction { try self.app.publishing.schedule(id: item.id, at: when,
                                                                   reviewer: self.user) }
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    /// Helper that runs a throwing domain action and presents a friendly error
    /// message on failure. Reloads the table on success so the state-aware UI
    /// reflects the new item status immediately.
    private func tryAction(_ body: () throws -> Void) {
        do {
            try body()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            tableView.reloadData()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            let msg: String
            switch error {
            case is AuthorizationError: msg = "You don't have permission to do that."
            case ContentError.notFound: msg = "Content item not found."
            case ContentError.invalidState: msg = "This action isn't available in the current state."
            case ContentError.cannotApproveOwnDraft: msg = "You can't approve your own draft."
            case ContentError.scheduleInPast: msg = "Scheduled time must be in the future."
            case ContentError.noPriorVersion: msg = "There's no previous version to roll back to."
            default: msg = "Something went wrong. Please try again."
            }
            let alert = UIAlertController(title: "Error", message: msg, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    // MARK: - Editor actions

    @objc private func newDraft() {
        // Five-step flow: kind → region → theme → rider type → title. Every
        // facet has an explicit "any" option so an author can scope broadly
        // without being forced into an arbitrary value. The full
        // `TaxonomyTag(region:theme:riderType:)` is persisted so customer
        // browse filters receive every facet.
        pickContentKind { [weak self] kind in
            self?.pickTaxonomyRegion { region in
                self?.pickTaxonomyTheme { theme in
                    self?.pickTaxonomyRiderType { riderType in
                        self?.promptTitleAndCreate(
                            kind: kind,
                            tag: TaxonomyTag(region: region,
                                             theme: theme,
                                             riderType: riderType))
                    }
                }
            }
        }
    }

    private func pickContentKind(_ completion: @escaping (ContentKind) -> Void) {
        let sheet = UIAlertController(title: "Content kind",
                                      message: "Pick the content type to author.",
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Travel advisory", style: .default) { _ in
            completion(.travelAdvisory)
        })
        sheet.addAction(UIAlertAction(title: "Onboard offer", style: .default) { _ in
            completion(.onboardOffer)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func pickTaxonomyRegion(_ completion: @escaping (Region?) -> Void) {
        let sheet = UIAlertController(title: "Taxonomy — region",
                                      message: "Scope this item to a region (or all regions).",
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Any region", style: .default) { _ in
            completion(nil)
        })
        for region in Region.allCases {
            sheet.addAction(UIAlertAction(title: region.rawValue.capitalized,
                                          style: .default) { _ in
                completion(region)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func pickTaxonomyTheme(_ completion: @escaping (Theme?) -> Void) {
        let sheet = UIAlertController(title: "Taxonomy — theme",
                                      message: "Tag the theme (or leave as any).",
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Any theme", style: .default) { _ in
            completion(nil)
        })
        for theme in Theme.allCases {
            sheet.addAction(UIAlertAction(title: theme.rawValue.capitalized,
                                          style: .default) { _ in
                completion(theme)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func pickTaxonomyRiderType(_ completion: @escaping (RiderType?) -> Void) {
        let sheet = UIAlertController(title: "Taxonomy — rider type",
                                      message: "Tag the rider audience (or leave as any).",
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Any rider type", style: .default) { _ in
            completion(nil)
        })
        for riderType in RiderType.allCases {
            sheet.addAction(UIAlertAction(title: riderType.rawValue.capitalized,
                                          style: .default) { _ in
                completion(riderType)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func promptTitleAndCreate(kind: ContentKind, tag: TaxonomyTag) {
        let alert = UIAlertController(title: "New \(kind == .travelAdvisory ? "Advisory" : "Offer")",
                                      message: "Enter title",
                                      preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Content title" }
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self, let title = alert.textFields?.first?.text, !title.isEmpty else { return }
            do {
                _ = try self.app.publishing.createDraft(
                    id: UUID().uuidString,
                    kind: kind,
                    title: title,
                    tag: tag,
                    body: "Draft content.",
                    editorId: self.user.id,
                    actingUser: self.user
                )
                self.tableView.reloadData()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                let msg: String
                switch error {
                case is AuthorizationError: msg = "You don't have permission to do that."
                case ContentError.notFound: msg = "Content item not found."
                case ContentError.invalidState: msg = "This action isn't available in the current state."
                default: msg = "Something went wrong. Please try again."
                }
                let err = UIAlertController(title: "Error", message: msg,
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
