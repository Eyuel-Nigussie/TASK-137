#if canImport(UIKit)
import UIKit
import RailCommerce

/// Customer-facing membership dashboard showing tier, points, and eligible campaigns.
/// Administrators can also view all members and manage campaigns via a role-gated section.
final class MembershipViewController: UITableViewController {

    private let app: RailCommerce
    private let user: User
    private var campaigns: [MarketingCampaign] = []
    private var allCampaigns: [MarketingCampaign] = []
    private let emptyLabel = UILabel()
    /// Whether the current user can manage campaigns.
    private var canManage: Bool { RolePolicy.can(user.role, .manageMembership) }

    init(app: RailCommerce, user: User) {
        self.app = app
        self.user = user
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Membership"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addTapped))
        navigationItem.rightBarButtonItem?.accessibilityLabel = canManage
            ? "Create campaign or enroll"
            : "Enroll in membership"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "campaign")
        emptyLabel.text = "Not enrolled yet.\nTap + to join the loyalty program."
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.numberOfLines = 0
        tableView.backgroundView = emptyLabel
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadData()
    }

    private func reloadData() {
        campaigns = app.membership.eligibleCampaigns(for: user.id)
        if canManage { allCampaigns = app.membership.allCampaigns() }
        emptyLabel.isHidden = app.membership.member(user.id) != nil || canManage
        tableView.reloadData()
    }

    // MARK: - Sections
    // 0: Your Status, 1: Offers For You, 2 (admin only): Manage Campaigns

    override func numberOfSections(in tableView: UITableView) -> Int {
        canManage ? 3 : 2
    }

    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "Your Status"
        case 1: return "Offers For You"
        case 2: return "Manage Campaigns"
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 1
        case 1: return campaigns.count
        case 2: return allCampaigns.count
        default: return 0
        }
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "campaign", for: indexPath)
        var config = cell.defaultContentConfiguration()
        switch indexPath.section {
        case 0:
            if let m = app.membership.member(user.id) {
                config.text = "Tier: \(m.tier.rawValue.capitalized)"
                config.secondaryText = "Points: \(m.pointsBalance)"
            } else {
                config.text = "Not enrolled"
                config.secondaryText = "Tap + to join"
            }
        case 1:
            let c = campaigns[indexPath.row]
            config.text = c.name
            config.secondaryText = c.offerDescription
        case 2:
            let c = allCampaigns[indexPath.row]
            config.text = c.name
            config.secondaryText = c.active ? "Active" : "Inactive"
        default: break
        }
        cell.contentConfiguration = config
        return cell
    }

    // MARK: - Swipe to deactivate (admin only)

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        guard indexPath.section == 2, canManage else { return nil }
        let campaign = allCampaigns[indexPath.row]
        guard campaign.active else { return nil }
        let deactivate = UIContextualAction(style: .destructive, title: "Deactivate") { [weak self] _, _, done in
            guard let self else { done(false); return }
            do {
                try self.app.membership.deactivateCampaign(campaign.id, actingUser: self.user)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.reloadData()
                done(true)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.showAlert("Error", message: "Could not deactivate campaign.")
                done(false)
            }
        }
        return UISwipeActionsConfiguration(actions: [deactivate])
    }

    // MARK: - Actions

    @objc private func addTapped() {
        if canManage {
            presentAdminActionSheet()
        } else {
            enrollSelf()
        }
    }

    private func presentAdminActionSheet() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        if app.membership.member(user.id) == nil {
            sheet.addAction(UIAlertAction(title: "Enroll Myself", style: .default) { [weak self] _ in
                self?.enrollSelf()
            })
        }
        sheet.addAction(UIAlertAction(title: "Create Campaign", style: .default) { [weak self] _ in
            self?.presentCampaignForm()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func enrollSelf() {
        guard app.membership.member(user.id) == nil else {
            showAlert("Already Enrolled", message: "You're already a member!")
            return
        }
        do {
            _ = try app.membership.enroll(userId: user.id, actingUser: user)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            reloadData()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showAlert("Error", message: "Could not enroll.")
        }
    }

    private func presentCampaignForm() {
        let form = UIAlertController(title: "New Campaign", message: nil, preferredStyle: .alert)
        form.addTextField { $0.placeholder = "Campaign name" }
        form.addTextField { $0.placeholder = "Offer description" }
        form.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self,
                  let name = form.textFields?[0].text, !name.isEmpty,
                  let desc = form.textFields?[1].text, !desc.isEmpty else { return }
            let campaign = MarketingCampaign(id: UUID().uuidString, name: name,
                                             offerDescription: desc)
            do {
                _ = try self.app.membership.createCampaign(campaign, actingUser: self.user)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.reloadData()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.showAlert("Error", message: "Could not create campaign.")
            }
        })
        form.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(form, animated: true)
    }

    private func showAlert(_ title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
#endif
