#if canImport(UIKit)
import UIKit
import RailCommerce
import RxSwift

/// Closed-loop messaging thread scoped to a single after-sales request.
/// Messages are stored in `MessagingService` with `threadId == request.id`, and
/// access is gated by `AfterSalesService.postCaseMessage` / `caseMessages`
/// which enforce per-case object-level visibility (request owner or CSR/admin).
final class AfterSalesCaseThreadViewController: UIViewController {

    private let app: RailCommerce
    private let user: User
    private let request: AfterSalesRequest
    private var messages: [Message] = []

    private var tableView: UITableView!
    private var composeField: UITextField!
    private var recipientField: UITextField!
    private var sendButton: UIButton!
    private let emptyLabel = UILabel()
    private let disposeBag = DisposeBag()

    init(app: RailCommerce, user: User, request: AfterSalesRequest) {
        self.app = app
        self.user = user
        self.request = request
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Case #\(request.id.prefix(6))"
        view.backgroundColor = .systemBackground
        // Default recipient: CSR addresses the customer; customer addresses CSR.
        let defaultRecipient = RolePolicy.can(user.role, .handleServiceTickets)
            ? (request.createdByUserId ?? "")
            : "csr"
        setupLayout(defaultRecipient: defaultRecipient)
        setupEmptyState()
        // Reactive refresh whenever a new message lands on the messaging bus.
        app.messaging.events
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] _ in self?.reload() })
            .disposed(by: disposeBag)
        reload()
    }

    // MARK: - Load / render

    private func reload() {
        messages = (try? app.afterSales.caseMessages(requestId: request.id,
                                                      actingUser: user)) ?? []
        emptyLabel.isHidden = !messages.isEmpty
        tableView.reloadData()
        if !messages.isEmpty {
            let last = IndexPath(row: messages.count - 1, section: 0)
            tableView.scrollToRow(at: last, at: .bottom, animated: false)
        }
    }

    private func setupEmptyState() {
        emptyLabel.text = "No case messages yet.\nSend the first one below."
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.numberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])
    }

    private func setupLayout(defaultRecipient: String) {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "case-msg")
        tableView.allowsSelection = false
        tableView.translatesAutoresizingMaskIntoConstraints = false

        recipientField = UITextField()
        recipientField.text = defaultRecipient
        recipientField.placeholder = "To (user ID)"
        recipientField.borderStyle = .roundedRect
        recipientField.font = .preferredFont(forTextStyle: .footnote)
        recipientField.adjustsFontForContentSizeCategory = true
        recipientField.accessibilityLabel = "Recipient user ID"
        recipientField.autocapitalizationType = .none
        recipientField.autocorrectionType = .no

        composeField = UITextField()
        composeField.placeholder = "Type your message…"
        composeField.borderStyle = .roundedRect
        composeField.font = .preferredFont(forTextStyle: .body)
        composeField.adjustsFontForContentSizeCategory = true
        composeField.accessibilityLabel = "Case message body"

        sendButton = UIButton(configuration: .filled())
        sendButton.setTitle("Send", for: .normal)
        sendButton.accessibilityLabel = "Send case message"
        sendButton.titleLabel?.adjustsFontForContentSizeCategory = true
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        let composeRow = UIStackView(arrangedSubviews: [composeField, sendButton])
        composeRow.axis = .horizontal
        composeRow.spacing = 8

        let bottomStack = UIStackView(arrangedSubviews: [recipientField, composeRow])
        bottomStack.axis = .vertical
        bottomStack.spacing = 6
        bottomStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tableView)
        view.addSubview(bottomStack)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -8),
            bottomStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bottomStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            bottomStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            sendButton.widthAnchor.constraint(equalToConstant: 70)
        ])
    }

    // MARK: - Send

    @objc private func sendTapped() {
        guard let body = composeField.text, !body.isEmpty,
              let to = recipientField.text, !to.isEmpty else { return }
        do {
            _ = try app.afterSales.postCaseMessage(requestId: request.id, to: to,
                                                    body: body, actingUser: user)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            composeField.text = nil
            app.messaging.drainQueue()
            reload()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            let msg: String
            switch error {
            case AfterSalesError.notFound: msg = "This case no longer exists."
            case AfterSalesError.orderNotOwned: msg = "You are not a participant of this case."
            case MessagingError.sensitiveDataBlocked: msg = "Message contains sensitive data."
            case MessagingError.harassmentBlocked: msg = "Message flagged by content filter."
            case MessagingError.blockedByRecipient: msg = "The recipient has blocked you."
            case MessagingError.senderIdentityMismatch: msg = "You can only send as yourself."
            default: msg = "Could not send the message."
            }
            let alert = UIAlertController(title: "Error", message: msg, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}

// MARK: - UITableViewDataSource

extension AfterSalesCaseThreadViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "case-msg", for: indexPath)
        let msg = messages[indexPath.row]
        var config = cell.defaultContentConfiguration()
        let prefix = msg.fromUserId == user.id ? "You" : msg.fromUserId
        config.text = "\(prefix): \(msg.body)"
        config.secondaryText = msg.deliveredAt == nil ? "Queued" : "Delivered"
        cell.contentConfiguration = config
        return cell
    }
}
#endif
