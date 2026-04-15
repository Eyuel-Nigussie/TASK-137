#if canImport(UIKit)
import UIKit
import RailCommerce

/// Seat selection and reservation for customers and sales agents.
final class SeatInventoryViewController: UITableViewController {

    private let app: RailCommerce
    private let user: User

    // Sample train/date/segment for demo; real app would be populated from catalog.
    private let sampleKey = SeatKey(trainId: "NE1", date: "2024-01-02",
                                    segmentId: "NY-BOS", seatClass: .economy, seatNumber: "12A")
    private var statusLabel: UILabel?

    init(app: RailCommerce, user: User) {
        self.app = app
        self.user = user
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Seat Inventory"
        app.seatInventory.registerSeat(sampleKey)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "seat")
    }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "seat", for: indexPath)
        var config = cell.defaultContentConfiguration()
        config.text = "\(sampleKey.trainId) — Seat \(sampleKey.seatNumber)"
        let state = app.seatInventory.state(sampleKey) ?? .available
        config.secondaryText = state.rawValue.capitalized
        cell.contentConfiguration = config
        cell.accessoryType = state == .available ? .disclosureIndicator : .none
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard app.seatInventory.state(sampleKey) == .available else {
            showAlert("Seat Unavailable", message: "This seat is already reserved or sold.")
            return
        }
        guard RolePolicy.can(user.role, .purchase) ||
              RolePolicy.can(user.role, .processTransaction) else {
            showAlert("Permission Denied", message: "You cannot reserve seats.")
            return
        }
        do {
            let res = try app.seatInventory.reserve(sampleKey,
                                                    holderId: user.id,
                                                    actingUser: user)
            showAlert("Reserved",
                      message: "Seat held until \(res.expiresAt.formatted(date: .omitted, time: .shortened))")
            tableView.reloadData()
        } catch {
            showAlert("Error", message: error.localizedDescription)
        }
    }

    private func showAlert(_ title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
#endif
