#if canImport(UIKit)
import UIKit
import RailCommerce

/// After-sales request list and creation flow for customers and CSRs.
final class AfterSalesViewController: UITableViewController {

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
        title = "Returns & Refunds"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(newRequest))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "req")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    // MARK: - UITableViewDataSource

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        app.afterSales.all().count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "req", for: indexPath)
        let req = app.afterSales.all()[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = "\(req.kind.rawValue) — \(req.orderId)"
        config.secondaryText = req.status.rawValue
        cell.contentConfiguration = config
        return cell
    }

    // MARK: - Actions

    @objc private func newRequest() {
        guard RolePolicy.can(user.role, .manageAfterSales) else {
            showAlert("Permission Denied", message: "You cannot open after-sales requests.")
            return
        }
        let req = AfterSalesRequest(
            id: UUID().uuidString,
            orderId: "O-\(Int.random(in: 1000...9999))",
            kind: .refundOnly,
            reason: .changedMind,
            createdAt: Date(),
            serviceDate: Date(),
            amountCents: 1_500
        )
        do {
            try app.afterSales.open(req, actingUser: user)
            tableView.reloadData()
        } catch {
            showAlert("Error", message: error.localizedDescription)
        }
    }

    // MARK: - CSR actions

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        guard RolePolicy.can(user.role, .handleServiceTickets) else { return nil }
        let req = app.afterSales.all()[indexPath.row]
        let approve = UIContextualAction(style: .normal, title: "Approve") { [weak self] _, _, done in
            try? self?.app.afterSales.approve(id: req.id, actingUser: self?.user)
            tableView.reloadData()
            done(true)
        }
        approve.backgroundColor = .systemGreen
        return UISwipeActionsConfiguration(actions: [approve])
    }

    private func showAlert(_ title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
#endif
