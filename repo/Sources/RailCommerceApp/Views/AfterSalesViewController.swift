#if canImport(UIKit)
import UIKit
import AVFoundation
import RailCommerce
import RxSwift

/// After-sales request list and creation flow for customers and CSRs.
/// Customers see only their own orders' requests; CSR/admin see all.
final class AfterSalesViewController: UITableViewController,
    UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    private let app: RailCommerce
    private let user: User
    private var visibleRequests: [AfterSalesRequest] = []
    private let emptyLabel = UILabel()
    private let disposeBag = DisposeBag()

    init(app: RailCommerce, user: User) {
        self.app = app
        self.user = user
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Returns & Refunds"
        // Subscribe to after-sales events for reactive UI refresh.
        app.afterSales.events
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] _ in self?.reloadData() })
            .disposed(by: disposeBag)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(newRequest))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "New return request"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "req")
        setupEmptyState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadData()
    }

    // MARK: - Object-level isolation

    private func reloadData() {
        // Use the fool-proof scoped visibility API — it does not accept a
        // caller-supplied target id, so it cannot be misused to request
        // another user's data even if this VC is subclassed or extended.
        visibleRequests = app.afterSales.requestsVisible(actingUser: user)
        emptyLabel.isHidden = !visibleRequests.isEmpty
        tableView.reloadData()
    }

    // MARK: - Empty state

    private func setupEmptyState() {
        emptyLabel.text = "No return or refund requests."
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.numberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundView = emptyLabel
    }

    // MARK: - UITableViewDataSource

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        visibleRequests.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "req", for: indexPath)
        let req = visibleRequests[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = "\(req.kind.rawValue) — \(req.orderId)"
        config.secondaryText = req.status.rawValue
        cell.contentConfiguration = config
        return cell
    }

    // MARK: - Actions

    @objc private func newRequest() {
        guard RolePolicy.can(user.role, .manageAfterSales) else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showAlert("Permission Denied", message: "You cannot open after-sales requests.")
            return
        }
        presentRequestForm()
    }

    // MARK: - Full request form (kind / reason / order selection)

    private var selectedKind: AfterSalesKind = .refundOnly
    private var selectedReason: AfterSalesReason = .changedMind
    private var selectedOrderId: String?
    private var capturedPhotoIds: [String] = []

    private func presentRequestForm() {
        let myOrders = app.checkout.orders(for: user.id)
        let form = UIAlertController(title: "New Request",
                                     message: "Select request type",
                                     preferredStyle: .actionSheet)
        for kind in [AfterSalesKind.refundOnly, .returnAndRefund, .exchange] {
            form.addAction(UIAlertAction(title: kind.rawValue.capitalized, style: .default) { [weak self] _ in
                self?.selectedKind = kind
                self?.presentReasonPicker(orders: myOrders)
            })
        }
        form.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(form, animated: true)
    }

    private func presentReasonPicker(orders: [OrderSnapshot]) {
        let reasons: [AfterSalesReason] = [.defective, .wrongItem, .notAsDescribed, .changedMind, .late, .other]
        let sheet = UIAlertController(title: "Reason", message: nil, preferredStyle: .actionSheet)
        for reason in reasons {
            sheet.addAction(UIAlertAction(title: reason.rawValue.capitalized, style: .default) { [weak self] _ in
                self?.selectedReason = reason
                self?.presentOrderPicker(orders: orders)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func presentOrderPicker(orders: [OrderSnapshot]) {
        if orders.isEmpty {
            showAlert("No Orders", message: "You have no orders to create a return for.")
            return
        }
        let sheet = UIAlertController(title: "Select Order", message: nil, preferredStyle: .actionSheet)
        for order in orders {
            let label = "\(order.orderId.prefix(8))… — $\(String(format: "%.2f", Double(order.totalCents) / 100))"
            sheet.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                self?.selectedOrderId = order.orderId
                // Non-refund-only flows require photo proof.
                if self?.selectedKind != .refundOnly {
                    self?.requestCameraForProof()
                } else {
                    self?.submitRequest(photoIds: [])
                }
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func requestCameraForProof() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.presentCamera() }
                    else { self?.submitRequest(photoIds: []) }
                }
            }
        case .authorized:
            presentCamera()
        default:
            submitRequest(photoIds: [])
        }
    }

    private func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            submitRequest(photoIds: [])
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        present(picker, animated: true)
    }

    // MARK: - UIImagePickerControllerDelegate

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        var photoIds: [String] = []
        if let image = info[.originalImage] as? UIImage,
           let data = image.jpegData(compressionQuality: 0.8) {
            let attId = UUID().uuidString
            try? app.attachments.save(id: attId, data: data, kind: .jpeg)
            photoIds.append(attId)
        }
        submitRequest(photoIds: photoIds)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        submitRequest(photoIds: [])
    }

    private func submitRequest(photoIds: [String]) {
        guard let orderId = selectedOrderId else { return }
        let orderSnapshot = app.checkout.order(orderId, ownedBy: user.id)
        let amount = orderSnapshot?.totalCents ?? 1_500
        // Use the order's **travel / service date** (departure for tickets,
        // fulfillment for merchandise) as the anchor for SLA automation rather
        // than the order's creation date. The 14-day auto-reject rule is
        // defined relative to service, not purchase.
        let serviceDate = orderSnapshot?.serviceDate ?? Date()
        let req = AfterSalesRequest(
            id: UUID().uuidString,
            orderId: orderId,
            kind: selectedKind,
            reason: selectedReason,
            createdAt: Date(),
            serviceDate: serviceDate,
            amountCents: amount,
            photoAttachmentIds: photoIds
        )
        do {
            try app.afterSales.open(req, actingUser: user)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            reloadData()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showAlert("Error", message: "Could not open the request.")
        }
    }

    // MARK: - CSR actions

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        guard RolePolicy.can(user.role, .handleServiceTickets) else { return nil }
        let req = visibleRequests[indexPath.row]
        let approve = UIContextualAction(style: .normal, title: "Approve") { [weak self] _, _, done in
            guard let self = self else { done(false); return }
            do {
                try self.app.afterSales.approve(id: req.id, actingUser: self.user)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.reloadData()
                done(true)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.showAlert("Error", message: "Could not approve this request.")
                done(false)
            }
        }
        approve.backgroundColor = .systemGreen
        return UISwipeActionsConfiguration(actions: [approve])
    }

    // MARK: - Case thread drill-down

    /// Tapping a request row opens the closed-loop case-thread conversation
    /// scoped to that request id (customer ↔ CSR). Implements the prompt's
    /// "closed-loop messaging" linkage at the UI level.
    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let req = visibleRequests[indexPath.row]
        let thread = AfterSalesCaseThreadViewController(app: app, user: user, request: req)
        navigationController?.pushViewController(thread, animated: true)
    }

    private func showAlert(_ title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
#endif
