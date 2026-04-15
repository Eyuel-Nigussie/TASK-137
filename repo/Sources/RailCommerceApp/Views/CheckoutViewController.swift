#if canImport(UIKit)
import UIKit
import RailCommerce

/// Checkout flow: address selection, shipping, invoice notes, and order submission.
final class CheckoutViewController: UIViewController {

    private let app: RailCommerce
    private let user: User
    private let cart: Cart

    private var selectedAddress: USAddress?
    private var selectedShipping = ShippingTemplate(id: "std", name: "Standard",
                                                    feeCents: 500, etaDays: 3)
    private var invoiceTextField: UITextField!

    init(app: RailCommerce, user: User, cart: Cart) {
        self.app = app
        self.user = user
        self.cart = cart
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Checkout"
        view.backgroundColor = .systemBackground
        selectedAddress = app.addressBook.defaultAddress
        setupLayout()
    }

    private func setupLayout() {
        let addrLabel = UILabel()
        addrLabel.text = "Shipping to: \(selectedAddress?.line1 ?? "No default address")"
        addrLabel.numberOfLines = 0

        let shippingLabel = UILabel()
        shippingLabel.text = "Shipping: \(selectedShipping.name) ($\(selectedShipping.feeCents / 100))"

        invoiceTextField = UITextField()
        invoiceTextField.placeholder = "Invoice notes (optional)"
        invoiceTextField.borderStyle = .roundedRect

        let submitButton = UIButton(configuration: .filled())
        submitButton.setTitle("Place Order", for: .normal)
        submitButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [addrLabel, shippingLabel, invoiceTextField, submitButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])
    }

    @objc private func submitTapped() {
        guard let address = selectedAddress else {
            showAlert("No Address", message: "Please add a shipping address.")
            return
        }
        let orderId = UUID().uuidString
        do {
            let snap = try app.checkout.submit(
                orderId: orderId,
                userId: user.id,
                cart: cart,
                discounts: [],
                address: address,
                shipping: selectedShipping,
                invoiceNotes: invoiceTextField.text ?? "",
                actingUser: user
            )
            showAlert("Order Placed", message: "Order \(snap.orderId.prefix(8)) confirmed!")
        } catch {
            showAlert("Checkout Failed", message: error.localizedDescription)
        }
    }

    private func showAlert(_ title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
#endif
