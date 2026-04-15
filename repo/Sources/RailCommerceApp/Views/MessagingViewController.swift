#if canImport(UIKit)
import UIKit
import RailCommerce

/// Peer-to-peer offline messaging view with contact masking and attachment upload.
final class MessagingViewController: UIViewController {

    private let app: RailCommerce
    private let user: User
    private var tableView: UITableView!
    private var composeField: UITextField!
    private var sendButton: UIButton!

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
        setupLayout()
    }

    private func setupLayout() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "msg")
        tableView.translatesAutoresizingMaskIntoConstraints = false

        composeField = UITextField()
        composeField.placeholder = "Type a message…"
        composeField.borderStyle = .roundedRect
        composeField.translatesAutoresizingMaskIntoConstraints = false

        sendButton = UIButton(configuration: .filled())
        sendButton.setTitle("Send", for: .normal)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        let composeBar = UIStackView(arrangedSubviews: [composeField, sendButton])
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
        guard let text = composeField.text, !text.isEmpty else { return }
        do {
            _ = try app.messaging.enqueue(id: UUID().uuidString,
                                          from: user.id, to: "support",
                                          body: text, actingUser: user)
            composeField.text = nil
            tableView.reloadData()
        } catch {
            let alert = UIAlertController(title: "Message Blocked",
                                          message: error.localizedDescription,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}

// MARK: - UITableViewDataSource

extension MessagingViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        app.messaging.queue.count + app.messaging.deliveredMessages.count
    }

    func tableView(_ tableView: UITableView,
                   cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "msg", for: indexPath)
        let all = app.messaging.queue + app.messaging.deliveredMessages
        let msg = all[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = msg.body
        config.secondaryText = msg.deliveredAt == nil ? "Queued" : "Delivered"
        cell.contentConfiguration = config
        return cell
    }
}
#endif
