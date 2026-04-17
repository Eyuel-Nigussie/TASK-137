#if canImport(UIKit)
import UIKit
import RailCommerce
import RxSwift

/// Dynamic seat selection and reservation. Renders all registered seats from the
/// inventory service, grouped by train/date/segment, instead of a single sample.
final class SeatInventoryViewController: UITableViewController {

    private let app: RailCommerce
    private let user: User
    private let disposeBag = DisposeBag()
    private var seats: [SeatKey] = []
    private let emptyLabel = UILabel()

    init(app: RailCommerce, user: User) {
        self.app = app
        self.user = user
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Seat Inventory"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(seedSampleSeats))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Add sample seats"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "seat")
        emptyLabel.text = "No seats registered.\nTap + to seed sample inventory."
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.numberOfLines = 0
        tableView.backgroundView = emptyLabel
        app.seatInventory.events
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] _ in self?.reloadSeats() })
            .disposed(by: disposeBag)
        reloadSeats()
    }

    private func reloadSeats() {
        // Derive the seat list from the service's persisted state so the UI
        // survives app restart and reflects all registered seats.
        seats = app.seatInventory.registeredKeys()
        emptyLabel.isHidden = !seats.isEmpty
        tableView.reloadData()
    }

    @objc private func seedSampleSeats() {
        let trains = ["NE1", "SW2", "MW3"]
        let classes: [SeatClass] = [.economy, .business, .first]
        do {
            for train in trains {
                for cls in classes {
                    for num in ["1A", "1B", "2A", "2B"] {
                        let key = SeatKey(trainId: train, date: "2024-06-15",
                                          segmentId: "\(train)-SEG",
                                          seatClass: cls, seatNumber: num)
                        if app.seatInventory.state(key) == nil {
                            // Guarded path — requires `.manageInventory`. Sales
                            // agent and admin succeed; customers are rejected
                            // at the trust boundary with AuthorizationError.
                            try app.seatInventory.registerSeat(key, actingUser: user)
                        }
                    }
                }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            let alert = UIAlertController(title: "Not authorized",
                                          message: "Only sales agents and admins can register seats.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
        reloadSeats()
    }

    // MARK: - UITableViewDataSource

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int { seats.count }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "seat", for: indexPath)
        let key = seats[indexPath.row]
        let state = app.seatInventory.state(key) ?? .available
        var config = cell.defaultContentConfiguration()
        config.text = "\(key.trainId) — \(key.seatClass.rawValue.capitalized) \(key.seatNumber)"
        config.secondaryText = "\(key.date) | \(state.rawValue.capitalized)"
        cell.contentConfiguration = config
        cell.accessoryType = state == .available ? .disclosureIndicator : .none
        return cell
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let key = seats[indexPath.row]
        guard app.seatInventory.state(key) == .available else {
            showAlert("Seat Unavailable", message: "This seat is already reserved or sold.")
            return
        }
        guard RolePolicy.can(user.role, .purchase) ||
              RolePolicy.can(user.role, .processTransaction) else {
            showAlert("Permission Denied", message: "You cannot reserve seats.")
            return
        }
        do {
            let res = try app.seatInventory.reserve(key, holderId: user.id, actingUser: user)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showAlert("Reserved",
                      message: "Seat held until \(res.expiresAt.formatted(date: .omitted, time: .shortened))")
            reloadSeats()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showAlert("Error", message: friendlyMessage(for: error))
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        switch error {
        case SeatError.unknownSeat:      return "This seat is not in the system."
        case SeatError.notAvailable:     return "This seat is not available."
        case SeatError.notReserved:      return "No active reservation for this seat."
        case SeatError.reservationExpired: return "Your reservation has expired."
        case SeatError.wrongHolder:      return "Reservation held by another user."
        case is AuthorizationError:      return "You don't have permission to do that."
        default:                         return "Something went wrong. Please try again."
        }
    }

    private func showAlert(_ title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
#endif
