#if canImport(UIKit)
import UIKit
import RailCommerce

/// Customer's shopping cart with bundle suggestions, promotion codes, and checkout flow.
final class CartViewController: UIViewController {

    private let app: RailCommerce
    private let user: User
    private let cart: Cart
    private var tableView: UITableView!
    private var checkoutButton: UIButton!

    init(app: RailCommerce, user: User) {
        self.app = app
        self.user = user
        self.cart = Cart(catalog: app.catalog)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Cart"
        view.backgroundColor = .systemBackground
        setupLayout()
    }

    private func setupLayout() {
        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "line")
        tableView.translatesAutoresizingMaskIntoConstraints = false

        checkoutButton = UIButton(configuration: .filled())
        checkoutButton.setTitle("Proceed to Checkout", for: .normal)
        checkoutButton.addTarget(self, action: #selector(checkoutTapped), for: .touchUpInside)
        checkoutButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tableView)
        view.addSubview(checkoutButton)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: checkoutButton.topAnchor, constant: -8),
            checkoutButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            checkoutButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            checkoutButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            checkoutButton.heightAnchor.constraint(equalToConstant: 50)
        ])
    }

    @objc private func checkoutTapped() {
        guard !cart.isEmpty else {
            showAlert("Cart is empty", message: "Please add items before checking out.")
            return
        }
        let vc = CheckoutViewController(app: app, user: user, cart: cart)
        navigationController?.pushViewController(vc, animated: true)
    }

    private func showAlert(_ title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - UITableViewDataSource

extension CartViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Items" : "Bundle Suggestions"
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? cart.lines.count : cart.bundleSuggestions().count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "line", for: indexPath)
        var config = cell.defaultContentConfiguration()
        if indexPath.section == 0 {
            let line = cart.lines[indexPath.row]
            config.text = "\(line.sku.title) × \(line.quantity)"
            config.secondaryText = String(format: "$%.2f", Double(line.subtotalCents) / 100)
        } else {
            let suggestion = cart.bundleSuggestions()[indexPath.row]
            config.text = "Bundle: \(suggestion.bundleId)"
            config.secondaryText = "Save \(String(format: "$%.2f", Double(suggestion.savingsCents) / 100))"
        }
        cell.contentConfiguration = config
        return cell
    }
}

// MARK: - UITableViewDelegate

extension CartViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        guard indexPath.section == 0, editingStyle == .delete else { return }
        let skuId = cart.lines[indexPath.row].sku.id
        try? cart.remove(skuId: skuId)
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }
}
#endif
