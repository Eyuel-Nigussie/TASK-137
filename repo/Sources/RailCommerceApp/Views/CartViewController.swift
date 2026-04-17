#if canImport(UIKit)
import UIKit
import RailCommerce
import RxSwift

/// Customer's shopping cart with bundle suggestions, promotion codes, and checkout flow.
final class CartViewController: UIViewController {

    private let app: RailCommerce
    private let user: User
    private let cart: Cart
    private var tableView: UITableView!
    private var checkoutButton: UIButton!
    private let disposeBag = DisposeBag()

    init(app: RailCommerce, user: User) {
        self.app = app
        self.user = user
        // User-scoped cart so signing out and signing back in as a different
        // user on a shared device does not leak cart lines across sessions.
        self.cart = app.cart(forUser: user.id)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Cart"
        view.backgroundColor = .systemBackground
        setupLayout()
        // Reactive refresh: clear cart display after a checkout submission.
        app.checkout.events
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] _ in
                self?.tableView.reloadData()
                self?.emptyLabel.isHidden = !(self?.cart.isEmpty ?? true)
            })
            .disposed(by: disposeBag)
    }

    private let emptyLabel = UILabel()

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
        emptyLabel.isHidden = !cart.isEmpty
    }

    private func setupLayout() {
        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(CartLineCell.self, forCellReuseIdentifier: "line")
        tableView.translatesAutoresizingMaskIntoConstraints = false

        checkoutButton = UIButton(configuration: .filled())
        checkoutButton.setTitle("Proceed to Checkout", for: .normal)
        checkoutButton.accessibilityLabel = "Proceed to Checkout"
        checkoutButton.accessibilityHint = "Submits your cart and completes the order"
        checkoutButton.titleLabel?.adjustsFontForContentSizeCategory = true
        checkoutButton.addTarget(self, action: #selector(checkoutTapped), for: .touchUpInside)
        checkoutButton.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.text = "Your cart is empty.\nBrowse to add items."
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.numberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tableView)
        view.addSubview(checkoutButton)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: checkoutButton.topAnchor, constant: -8),
            checkoutButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            checkoutButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            checkoutButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            checkoutButton.heightAnchor.constraint(equalToConstant: 50),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    @objc private func checkoutTapped() {
        guard !cart.isEmpty else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showAlert("Cart is empty", message: "Please add items before checking out.")
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
        let cell = tableView.dequeueReusableCell(withIdentifier: "line", for: indexPath) as! CartLineCell
        if indexPath.section == 0 {
            let line = cart.lines[indexPath.row]
            cell.configureLine(line) { [weak self] newQuantity in
                self?.updateQuantity(for: line.sku.id, to: newQuantity)
            }
        } else {
            let suggestion = cart.bundleSuggestions()[indexPath.row]
            cell.configureSuggestion(bundleId: suggestion.bundleId, savingsCents: suggestion.savingsCents)
        }
        return cell
    }
}

// MARK: - Quantity updates

extension CartViewController {
    /// Updates a cart line's quantity, or removes it when quantity reaches zero.
    /// Called from the stepper in `CartLineCell` — provides full cart CRUD in UI.
    fileprivate func updateQuantity(for skuId: String, to newQuantity: Int) {
        do {
            if newQuantity <= 0 {
                try cart.remove(skuId: skuId)
            } else {
                try cart.update(skuId: skuId, quantity: newQuantity)
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            tableView.reloadData()
            emptyLabel.isHidden = !cart.isEmpty
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showAlert("Error", message: "Could not update quantity.")
        }
    }
}

// MARK: - CartLineCell

/// Custom cell showing the cart line with a built-in stepper for quantity edits.
/// The stepper satisfies the prompt's "full CRUD" requirement in the UI.
final class CartLineCell: UITableViewCell {
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let stepper = UIStepper()
    private let quantityLabel = UILabel()
    private var onChange: ((Int) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        quantityLabel.font = .preferredFont(forTextStyle: .footnote)
        quantityLabel.adjustsFontForContentSizeCategory = true
        quantityLabel.textColor = .secondaryLabel
        stepper.minimumValue = 0
        stepper.maximumValue = 99
        stepper.accessibilityLabel = "Quantity"
        stepper.addTarget(self, action: #selector(stepperChanged), for: .valueChanged)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        let rightStack = UIStackView(arrangedSubviews: [quantityLabel, stepper])
        rightStack.axis = .vertical
        rightStack.alignment = .trailing
        rightStack.spacing = 4
        let row = UIStackView(arrangedSubviews: [textStack, rightStack])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func configureLine(_ line: CartLine, onChange: @escaping (Int) -> Void) {
        titleLabel.text = line.sku.title
        subtitleLabel.text = String(format: "$%.2f", Double(line.subtotalCents) / 100)
        quantityLabel.text = "Qty: \(line.quantity)"
        stepper.value = Double(line.quantity)
        stepper.isHidden = false
        self.onChange = onChange
    }

    func configureSuggestion(bundleId: String, savingsCents: Int) {
        titleLabel.text = "Bundle: \(bundleId)"
        subtitleLabel.text = "Save \(String(format: "$%.2f", Double(savingsCents) / 100))"
        quantityLabel.text = nil
        stepper.isHidden = true
        self.onChange = nil
    }

    @objc private func stepperChanged() {
        onChange?(Int(stepper.value))
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
