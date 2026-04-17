#if canImport(UIKit)
import UIKit
import RailCommerce
import RxSwift

/// Peer-to-peer offline messaging view with contact masking, attachment upload,
/// and object-level data isolation (users only see their own messages).
final class MessagingViewController: UIViewController {

    private let app: RailCommerce
    private let user: User
    private var visibleMessages: [Message] = []
    private var tableView: UITableView!
    private var composeField: UITextField!
    private var sendButton: UIButton!
    private var attachButton: UIButton!
    private let emptyLabel = UILabel()
    private let disposeBag = DisposeBag()

    /// Attachments queued for the next outgoing message. Cleared after every
    /// successful enqueue. Populated by the Attach button's picker.
    private var pendingAttachments: [MessageAttachment] = []

    init(app: RailCommerce, user: User) {
        self.app = app
        self.user = user
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Messages"
        view.backgroundColor = .systemBackground
        // Reactive refresh on queue drain events.
        app.messaging.events
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] _ in self?.reloadVisibleMessages() })
            .disposed(by: disposeBag)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Report", style: .plain, target: self, action: #selector(reportTapped))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Report abuse"
        setupLayout()
        setupEmptyState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Attempt to deliver any queued messages each time the view appears
        // (covers periodic retry on tab switch and peer-reconnect scenarios).
        app.messaging.drainQueue()
        reloadVisibleMessages()
    }

    // MARK: - Object-level isolation

    private func reloadVisibleMessages() {
        // Use the scoped API: user sees only their own sent + received messages.
        visibleMessages = (try? app.messaging.messagesVisibleTo(user.id, actingUser: user)) ?? []
        // Also include queued (not yet delivered) messages from this user.
        let queued = app.messaging.queue.filter { $0.fromUserId == user.id }
        visibleMessages = queued + visibleMessages
        emptyLabel.isHidden = !visibleMessages.isEmpty
        tableView.reloadData()
    }

    // MARK: - Empty state

    private func setupEmptyState() {
        emptyLabel.text = "No messages yet."
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

    private func setupLayout() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "msg")
        tableView.translatesAutoresizingMaskIntoConstraints = false

        composeField = UITextField()
        composeField.placeholder = "Type a message..."
        composeField.borderStyle = .roundedRect
        composeField.font = .preferredFont(forTextStyle: .body)
        composeField.adjustsFontForContentSizeCategory = true
        composeField.accessibilityLabel = "Message body"
        composeField.translatesAutoresizingMaskIntoConstraints = false

        attachButton = UIButton(configuration: .bordered())
        attachButton.setImage(UIImage(systemName: "paperclip"), for: .normal)
        attachButton.accessibilityLabel = "Attach file"
        attachButton.accessibilityHint = "Attach a JPEG, PNG, or PDF to the next message"
        attachButton.addTarget(self, action: #selector(attachTapped), for: .touchUpInside)
        attachButton.translatesAutoresizingMaskIntoConstraints = false

        sendButton = UIButton(configuration: .filled())
        sendButton.setTitle("Send", for: .normal)
        sendButton.accessibilityLabel = "Send message"
        sendButton.titleLabel?.adjustsFontForContentSizeCategory = true
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        let composeBar = UIStackView(arrangedSubviews: [attachButton, composeField, sendButton])
        composeBar.axis = .horizontal
        composeBar.spacing = 8
        composeBar.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tableView)
        view.addSubview(composeBar)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: composeBar.topAnchor, constant: -8),
            composeBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            composeBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            composeBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            sendButton.widthAnchor.constraint(equalToConstant: 70)
        ])
    }

    @objc private func sendTapped() {
        let text = composeField.text ?? ""
        // Allow attachment-only messages (empty body), but require at least one
        // of: non-empty text or a pending attachment.
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }
        // Show recipient picker with known peers and fallback user IDs.
        presentRecipientPicker { [weak self] recipientId in
            guard let self = self else { return }
            let attachments = self.pendingAttachments
            do {
                _ = try self.app.messaging.enqueue(id: UUID().uuidString,
                                                    from: self.user.id, to: recipientId,
                                                    body: text,
                                                    attachments: attachments,
                                                    actingUser: self.user)
                // Immediately attempt delivery after enqueue.
                self.app.messaging.drainQueue()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self.composeField.text = nil
                self.pendingAttachments = []
                self.refreshAttachButtonState()
                self.reloadVisibleMessages()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                let alert = UIAlertController(title: "Message Blocked",
                                              message: self.friendlyMessage(for: error),
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(alert, animated: true)
            }
        }
    }

    /// Presents the attachment picker. To keep the flow testable and free of
    /// runtime camera/photo-library permission dialogs (which the simulator
    /// cannot grant reliably in CI), the picker offers three deterministic
    /// fixture attachments — one per supported kind — that are staged through
    /// `AttachmentService` so the retention sweep sees them and the
    /// `MessagingService` attachment-size check exercises the real path.
    @objc private func attachTapped() {
        let sheet = UIAlertController(
            title: "Attach",
            message: "Attach a sample \(pendingAttachments.count > 0 ? "(you already have \(pendingAttachments.count) queued)" : "file") to the next message.",
            preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "JPEG sample", style: .default) { [weak self] _ in
            self?.stageAttachment(kind: .jpeg)
        })
        sheet.addAction(UIAlertAction(title: "PNG sample", style: .default) { [weak self] _ in
            self?.stageAttachment(kind: .png)
        })
        sheet.addAction(UIAlertAction(title: "PDF sample", style: .default) { [weak self] _ in
            self?.stageAttachment(kind: .pdf)
        })
        if !pendingAttachments.isEmpty {
            sheet.addAction(UIAlertAction(title: "Clear queued attachments",
                                          style: .destructive) { [weak self] _ in
                self?.pendingAttachments = []
                self?.refreshAttachButtonState()
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    /// Saves a fixture blob via `AttachmentService` and queues a
    /// `MessageAttachment` descriptor for the next outgoing message.
    private func stageAttachment(kind: AttachmentKind) {
        let id = UUID().uuidString
        // 16-byte fixture is far below the 10 MB MessagingService limit so the
        // size guard passes; the `.completeFileProtection` path in
        // DiskFileStore is exercised on-device, in-memory otherwise.
        let payload = Data(repeating: 0x42, count: 16)
        do {
            _ = try app.attachments.save(id: id, data: payload, kind: kind)
            pendingAttachments.append(MessageAttachment(id: id, kind: kind,
                                                        sizeBytes: payload.count))
            refreshAttachButtonState()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            let alert = UIAlertController(title: "Attach failed",
                                          message: "\(error)",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    private func refreshAttachButtonState() {
        let count = pendingAttachments.count
        attachButton.setTitle(count > 0 ? " \(count)" : nil, for: .normal)
        attachButton.accessibilityValue = count > 0 ? "\(count) attached" : "none attached"
    }

    /// Presents a picker of known peer/user identities for message routing.
    private func presentRecipientPicker(completion: @escaping (String) -> Void) {
        let sheet = UIAlertController(title: "Send To", message: nil, preferredStyle: .actionSheet)
        // Show connected transport peers as primary options.
        let peers = app.transport.connectedPeers
        for peer in peers {
            sheet.addAction(UIAlertAction(title: peer, style: .default) { _ in
                completion(peer)
            })
        }
        // Manual entry fallback for offline-queued messages.
        sheet.addAction(UIAlertAction(title: "Enter User ID...", style: .default) { [weak self] _ in
            let input = UIAlertController(title: "Recipient", message: "Enter the user ID:",
                                          preferredStyle: .alert)
            input.addTextField { $0.placeholder = "User ID" }
            input.addAction(UIAlertAction(title: "Send", style: .default) { _ in
                if let uid = input.textFields?.first?.text, !uid.isEmpty {
                    completion(uid)
                }
            })
            input.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            self?.present(input, animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    @objc private func reportTapped() {
        let alert = UIAlertController(title: "Report Abuse",
                                      message: "Enter the user ID to report:",
                                      preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "User ID" }
        alert.addAction(UIAlertAction(title: "Report", style: .destructive) { [weak self] _ in
            guard let self = self,
                  let targetId = alert.textFields?.first?.text, !targetId.isEmpty else { return }
            try? self.app.messaging.reportUser(targetId, reportedBy: self.user.id,
                                                reason: "Reported via UI",
                                                actingUser: self.user)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            self.showAlert("Reported", message: "User \(targetId) has been reported. Thank you.")
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func friendlyMessage(for error: Error) -> String {
        switch error {
        case MessagingError.sensitiveDataBlocked: return "Message contains sensitive data."
        case MessagingError.attachmentTooLarge:   return "Attachment exceeds the 10 MB limit."
        case MessagingError.attachmentTypeNotAllowed: return "This attachment type isn't allowed."
        case MessagingError.harassmentBlocked:    return "Message flagged by the harassment filter."
        case MessagingError.blockedByRecipient:   return "The recipient has blocked you."
        case MessagingError.senderIdentityMismatch: return "You can only send messages as yourself."
        default: return "Message could not be sent."
        }
    }

    private func showAlert(_ title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - UITableViewDataSource

extension MessagingViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        visibleMessages.count
    }

    func tableView(_ tableView: UITableView,
                   cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "msg", for: indexPath)
        let msg = visibleMessages[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = msg.body
        config.secondaryText = msg.deliveredAt == nil ? "Queued" : "Delivered"
        cell.contentConfiguration = config
        return cell
    }
}
#endif
