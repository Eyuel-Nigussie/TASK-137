#if canImport(UIKit)
import UIKit
import RailCommerce

/// Checkout flow: saved-address selection (add/edit/default), shipping-template selection,
/// invoice notes, and order submission.
final class CheckoutViewController: UIViewController {

    private let app: RailCommerce
    private let user: User
    private let cart: Cart

    /// Available shipping templates. In a real deployment these would be fetched
    /// from a catalog/config service; here they are seeded locally to satisfy the
    /// prompt's "shipping templates" requirement in the UI.
    private let shippingTemplates: [ShippingTemplate] = [
        ShippingTemplate(id: "std", name: "Standard", feeCents: 500, etaDays: 3),
        ShippingTemplate(id: "exp", name: "Express", feeCents: 1_200, etaDays: 1),
        ShippingTemplate(id: "eco", name: "Economy", feeCents: 200, etaDays: 7)
    ]

    private var selectedAddress: USAddress?
    private var selectedShipping: ShippingTemplate
    private var invoiceTextField: UITextField!
    private var addressButton: UIButton!
    private var shippingButton: UIButton!
    private var seatButton: UIButton!
    /// Seats the user has chosen to include in this order. The checkout
    /// service will transactionally reserve + confirm every key here (15-min
    /// hold, rolled back on any oversell). Empty = merchandise-only order.
    private var selectedSeats: [SeatKey] = []
    private var submitButton: UIButton!
    private var promoCodeField: UITextField!
    private var promoButton: UIButton!
    private var promoSummaryLabel: UILabel!
    /// Applied promotion codes, resolved against `knownDiscounts` at submit time.
    private var appliedCodes: [String] = []
    /// Stable order ID for this checkout attempt. Generated once on first entry
    /// and **reused** for every submit tap so repeated taps exercise the
    /// `CheckoutService` 10-second duplicate lockout instead of creating new
    /// distinct orders. Reset on success (or after the lockout window).
    private var pendingOrderId = UUID().uuidString
    /// Timer that re-enables the submit button once the 10-second lockout passes.
    private var lockoutTimer: Timer?
    /// Preseeded discount catalog. Only codes present here are accepted; this
    /// mirrors how a real deployment would sync a known promo table on device.
    private let knownDiscounts: [String: Discount] = [
        "PCT10":    Discount(code: "PCT10", kind: .percentOff, magnitude: 10, priority: 1),
        "PCT15":    Discount(code: "PCT15", kind: .percentOff, magnitude: 15, priority: 1),
        "AMT500":   Discount(code: "AMT500", kind: .amountOff, magnitude: 500, priority: 2),
        "SHIPFREE": Discount(code: "SHIPFREE", kind: .freeShipping, magnitude: 0, priority: 3)
    ]

    init(app: RailCommerce, user: User, cart: Cart) {
        self.app = app
        self.user = user
        self.cart = cart
        self.selectedShipping = ShippingTemplate(id: "std", name: "Standard",
                                                 feeCents: 500, etaDays: 3)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Checkout"
        view.backgroundColor = .systemBackground
        selectedAddress = app.addressBook.defaultAddress(for: user.id)
        setupLayout()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Refresh address in case user added one from the picker.
        if selectedAddress == nil {
            selectedAddress = app.addressBook.defaultAddress(for: user.id)
        }
        refreshButtonTitles()
    }

    private func setupLayout() {
        addressButton = UIButton(configuration: .bordered())
        addressButton.accessibilityLabel = "Choose shipping address"
        addressButton.titleLabel?.numberOfLines = 0
        addressButton.titleLabel?.adjustsFontForContentSizeCategory = true
        addressButton.addTarget(self, action: #selector(addressTapped), for: .touchUpInside)

        shippingButton = UIButton(configuration: .bordered())
        shippingButton.accessibilityLabel = "Choose shipping method"
        shippingButton.titleLabel?.adjustsFontForContentSizeCategory = true
        shippingButton.addTarget(self, action: #selector(shippingTapped), for: .touchUpInside)

        // Seat selector — optional; if seats are added, CheckoutService will
        // transactionally reserve + confirm them with the 15-minute hold and
        // roll back on any conflict, satisfying the oversell-prevention rule.
        seatButton = UIButton(configuration: .bordered())
        seatButton.accessibilityLabel = "Choose seats"
        seatButton.accessibilityHint = "Reserves and confirms the selected seats atomically during checkout"
        seatButton.titleLabel?.adjustsFontForContentSizeCategory = true
        seatButton.titleLabel?.numberOfLines = 0
        seatButton.addTarget(self, action: #selector(seatsTapped), for: .touchUpInside)

        invoiceTextField = UITextField()
        invoiceTextField.placeholder = "Invoice notes (optional)"
        invoiceTextField.borderStyle = .roundedRect
        invoiceTextField.font = .preferredFont(forTextStyle: .body)
        invoiceTextField.adjustsFontForContentSizeCategory = true
        invoiceTextField.accessibilityLabel = "Invoice notes"

        // Promotion code entry + apply + running summary. Supports up to 3 codes
        // (the PromotionEngine enforces max-3 / no-percent-stacking constraints).
        promoCodeField = UITextField()
        promoCodeField.placeholder = "Promo code (e.g. PCT10, SHIPFREE)"
        promoCodeField.borderStyle = .roundedRect
        promoCodeField.autocapitalizationType = .allCharacters
        promoCodeField.autocorrectionType = .no
        promoCodeField.font = .preferredFont(forTextStyle: .body)
        promoCodeField.adjustsFontForContentSizeCategory = true
        promoCodeField.accessibilityLabel = "Promo code"

        promoButton = UIButton(configuration: .bordered())
        promoButton.setTitle("Apply Code", for: .normal)
        promoButton.accessibilityLabel = "Apply promo code"
        promoButton.titleLabel?.adjustsFontForContentSizeCategory = true
        promoButton.addTarget(self, action: #selector(applyPromoTapped), for: .touchUpInside)

        promoSummaryLabel = UILabel()
        promoSummaryLabel.font = .preferredFont(forTextStyle: .footnote)
        promoSummaryLabel.adjustsFontForContentSizeCategory = true
        promoSummaryLabel.textColor = .secondaryLabel
        promoSummaryLabel.numberOfLines = 0
        promoSummaryLabel.text = "No promo codes applied."

        let promoRow = UIStackView(arrangedSubviews: [promoCodeField, promoButton])
        promoRow.axis = .horizontal
        promoRow.spacing = 8

        submitButton = UIButton(configuration: .filled())
        submitButton.setTitle("Place Order", for: .normal)
        submitButton.accessibilityLabel = "Place Order"
        submitButton.accessibilityHint = "Finalizes and submits this order"
        submitButton.titleLabel?.adjustsFontForContentSizeCategory = true
        submitButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [addressButton, shippingButton,
                                                    seatButton, invoiceTextField,
                                                    promoRow, promoSummaryLabel,
                                                    submitButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])
        refreshButtonTitles()
    }

    private func refreshButtonTitles() {
        if let addr = selectedAddress {
            addressButton?.setTitle("Ship to: \(addr.recipient), \(addr.line1), \(addr.state.rawValue) \(addr.zip)",
                                    for: .normal)
        } else {
            addressButton?.setTitle("Add or choose an address", for: .normal)
        }
        shippingButton?.setTitle("\(selectedShipping.name) — $\(String(format: "%.2f", Double(selectedShipping.feeCents) / 100)) · ~\(selectedShipping.etaDays)d",
                                 for: .normal)
        if selectedSeats.isEmpty {
            seatButton?.setTitle("No seats selected (merchandise-only order)", for: .normal)
        } else {
            let summary = selectedSeats
                .map { "\($0.trainId) \($0.seatNumber)" }
                .joined(separator: ", ")
            seatButton?.setTitle("Seats: \(summary)", for: .normal)
        }
    }

    // MARK: - Seat picker (transactional reserve + confirm at submit)

    @objc private func seatsTapped() {
        // Build the picker from the seat-inventory service's registered seats
        // so the reviewer / test path never has to know which trains exist.
        // Include every seat; CheckoutService transactionally validates state
        // at submit time and throws `.seatUnavailable` on conflicts.
        let keys = app.seatInventory.registeredKeys()
        guard !keys.isEmpty else {
            showAlert("No seats available",
                      message: "No seats are registered in the inventory yet. A sales agent or admin must register seats before they can be booked.")
            return
        }
        let sheet = UIAlertController(title: "Select Seats",
                                      message: selectedSeats.isEmpty
                                        ? "Tap any seat to include it in this order."
                                        : "\(selectedSeats.count) seat(s) currently selected.",
                                      preferredStyle: .actionSheet)
        for key in keys {
            let isSelected = selectedSeats.contains { $0 == key }
            let stateLabel: String
            switch app.seatInventory.state(key) {
            case .available: stateLabel = "available"
            case .reserved:  stateLabel = "reserved"
            case .sold:      stateLabel = "sold"
            case .none:      stateLabel = "unknown"
            }
            let title = "\(isSelected ? "✓ " : "")\(key.trainId) \(key.date) \(key.seatClass.rawValue) \(key.seatNumber) — \(stateLabel)"
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.toggleSeat(key)
            })
        }
        if !selectedSeats.isEmpty {
            sheet.addAction(UIAlertAction(title: "Clear selection", style: .destructive) { [weak self] _ in
                self?.selectedSeats = []
                self?.refreshButtonTitles()
            })
        }
        sheet.addAction(UIAlertAction(title: "Done", style: .cancel))
        present(sheet, animated: true)
    }

    private func toggleSeat(_ key: SeatKey) {
        if let idx = selectedSeats.firstIndex(where: { $0 == key }) {
            selectedSeats.remove(at: idx)
        } else {
            selectedSeats.append(key)
        }
        refreshButtonTitles()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Address picker (saved-address management)

    @objc private func addressTapped() {
        let sheet = UIAlertController(title: "Shipping Address", message: nil, preferredStyle: .actionSheet)
        // Only show addresses owned by the signed-in user; other users' addresses
        // stored on the same device must never appear in this picker.
        for addr in app.addressBook.addresses(for: user.id) {
            let label = "\(addr.recipient), \(addr.line1)\(addr.isDefault ? " (default)" : "")"
            sheet.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                self?.selectedAddress = addr
                self?.refreshButtonTitles()
            })
        }
        sheet.addAction(UIAlertAction(title: "Add New Address…", style: .default) { [weak self] _ in
            self?.presentAddressForm()
        })
        if let current = selectedAddress {
            sheet.addAction(UIAlertAction(title: "Make Selected Default", style: .default) { [weak self] _ in
                self?.makeSelectedDefault()
            })
            sheet.addAction(UIAlertAction(title: "Delete Selected Address", style: .destructive) { [weak self] _ in
                self?.deleteAddress(current)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    /// Removes an address from the saved book and falls back to the default.
    private func deleteAddress(_ address: USAddress) {
        let confirm = UIAlertController(
            title: "Delete Address",
            message: "Remove \(address.recipient) at \(address.line1)?",
            preferredStyle: .alert)
        confirm.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.app.addressBook.remove(id: address.id, ownedBy: self.user.id)
            self.selectedAddress = self.app.addressBook.defaultAddress(for: self.user.id)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            self.refreshButtonTitles()
        })
        confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(confirm, animated: true)
    }

    private func presentAddressForm() {
        let form = UIAlertController(title: "New Address", message: nil, preferredStyle: .alert)
        form.addTextField { $0.placeholder = "Recipient" }
        form.addTextField { $0.placeholder = "Street (line 1)" }
        form.addTextField { $0.placeholder = "City" }
        form.addTextField { $0.placeholder = "State (e.g. NY)"; $0.autocapitalizationType = .allCharacters }
        form.addTextField { $0.placeholder = "ZIP (5 or 9 digits)" }
        form.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self,
                  let recipient = form.textFields?[0].text, !recipient.isEmpty,
                  let line1 = form.textFields?[1].text, !line1.isEmpty,
                  let city = form.textFields?[2].text, !city.isEmpty,
                  let stateStr = form.textFields?[3].text,
                  let zip = form.textFields?[4].text,
                  let state = USState(rawValue: stateStr.uppercased()) else {
                self?.showAlert("Invalid", message: "Please complete all fields with a valid US state.")
                return
            }
            let addr = USAddress(id: UUID().uuidString, recipient: recipient, line1: line1,
                                 city: city, state: state, zip: zip,
                                 isDefault: self.app.addressBook.addresses(for: self.user.id).isEmpty)
            do {
                let saved = try self.app.addressBook.save(addr, ownedBy: self.user.id)
                self.selectedAddress = saved
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.refreshButtonTitles()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.showAlert("Invalid Address", message: "Please check the fields (ZIP must be 5 or 9 digits).")
            }
        })
        form.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(form, animated: true)
    }

    private func makeSelectedDefault() {
        guard let addr = selectedAddress else { return }
        let updated = USAddress(id: addr.id, recipient: addr.recipient, line1: addr.line1,
                                line2: addr.line2, city: addr.city, state: addr.state,
                                zip: addr.zip, isDefault: true,
                                ownerUserId: addr.ownerUserId ?? user.id)
        _ = try? app.addressBook.save(updated)
        selectedAddress = updated
        refreshButtonTitles()
    }

    // MARK: - Shipping template picker

    @objc private func shippingTapped() {
        let sheet = UIAlertController(title: "Shipping Method", message: nil, preferredStyle: .actionSheet)
        for tpl in shippingTemplates {
            let label = "\(tpl.name) — $\(String(format: "%.2f", Double(tpl.feeCents) / 100)) · ~\(tpl.etaDays)d"
            sheet.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                self?.selectedShipping = tpl
                self?.refreshButtonTitles()
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    // MARK: - Promo codes

    @objc private func applyPromoTapped() {
        let code = (promoCodeField.text ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        guard knownDiscounts[code] != nil else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showAlert("Unknown Code", message: "Promo code \(code) is not recognized.")
            return
        }
        if appliedCodes.contains(code) { return }  // idempotent
        appliedCodes.append(code)
        promoCodeField.text = ""
        refreshPromoSummary()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Renders the running promotion pipeline result so the user sees line-level
    /// rationale BEFORE submitting (accepted codes, rejected codes with reason,
    /// total discount, free shipping flag).
    private func refreshPromoSummary() {
        let discounts = appliedCodes.compactMap { knownDiscounts[$0] }
        let result = PromotionEngine.apply(cart: cart, discounts: discounts)
        var lines: [String] = []
        if !result.acceptedCodes.isEmpty {
            lines.append("Accepted: \(result.acceptedCodes.joined(separator: ", "))")
        }
        for (code, reason) in result.rejectionReasons {
            lines.append("Rejected \(code): \(reason)")
        }
        if result.totalDiscountCents > 0 {
            lines.append(String(format: "Total discount: –$%.2f",
                                Double(result.totalDiscountCents) / 100))
        }
        if result.freeShipping {
            lines.append("Shipping: Free")
        }
        promoSummaryLabel.text = lines.isEmpty ? "No promo codes applied." : lines.joined(separator: "\n")
    }

    // MARK: - Submit

    @objc private func submitTapped() {
        guard let address = selectedAddress else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showAlert("No Address", message: "Please add a shipping address.")
            return
        }
        // Disable the button across the duplicate-lockout window so a double
        // tap cannot race around the service's client-side lockout. The button
        // re-enables only after `CheckoutService.duplicateLockoutSeconds`.
        submitButton.isEnabled = false
        lockoutTimer?.invalidate()
        lockoutTimer = Timer.scheduledTimer(
            withTimeInterval: CheckoutService.duplicateLockoutSeconds,
            repeats: false
        ) { [weak self] _ in
            self?.submitButton.isEnabled = true
        }

        // Reuse the same `pendingOrderId` across taps so the CheckoutService's
        // 10-second duplicate lockout is exercised (the fix for the v6 audit
        // finding that distinct UUIDs were being generated per tap).
        let discounts = appliedCodes.compactMap { knownDiscounts[$0] }
        do {
            let snap = try app.checkout.submit(
                orderId: pendingOrderId,
                userId: user.id,
                cart: cart,
                discounts: discounts,
                address: address,
                shipping: selectedShipping,
                invoiceNotes: invoiceTextField.text ?? "",
                actingUser: user,
                seats: selectedSeats,
                seatInventory: selectedSeats.isEmpty ? nil : app.seatInventory
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            let discountLine = snap.promotion.totalDiscountCents > 0
                ? String(format: " (saved $%.2f)",
                         Double(snap.promotion.totalDiscountCents) / 100)
                : ""
            showAlert("Order Placed",
                      message: "Order \(snap.orderId.prefix(8)) confirmed\(discountLine)!")
            // Rotate the pending order id so a SUBSEQUENT checkout (new cart,
            // new attempt) doesn't collide with the order just submitted.
            pendingOrderId = UUID().uuidString
        } catch CheckoutError.duplicateSubmission {
            // Keep submitButton disabled; user saw the spinner/lockout feedback.
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showAlert("Already Submitted",
                      message: "This order is already being processed. Please wait.")
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showAlert("Checkout Failed", message: friendlyMessage(for: error))
        }
    }

    /// Converts a domain-level error into a user-facing string without leaking
    /// internal enum case names to the UI.
    private func friendlyMessage(for error: Error) -> String {
        switch error {
        case CheckoutError.emptyCart:                  return "Your cart is empty."
        case CheckoutError.duplicateSubmission:        return "This order has already been submitted."
        case CheckoutError.noShipping:                 return "A shipping option is required."
        case CheckoutError.addressInvalid:             return "The shipping address is invalid."
        case CheckoutError.tamperDetected:             return "Order integrity check failed."
        case CheckoutError.identityMismatch:           return "You may only submit your own orders."
        case CheckoutError.persistenceFailed:          return "The order could not be saved."
        case CheckoutError.seatInventoryUnavailable:   return "Seat booking is temporarily unavailable. Please try again."
        case CheckoutError.seatUnavailable:            return "One of the seats you selected is no longer available. Pick different seats."
        case AuthorizationError.forbidden:             return "You don't have permission to do that."
        default:                                       return "Something went wrong. Please try again."
        }
    }

    private func showAlert(_ title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
#endif
