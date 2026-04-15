#if canImport(UIKit)
import UIKit
import RailCommerce

/// Entry-point view controller. Authenticates the user via biometrics or
/// passcode (LocalAuthentication) then routes to the role-appropriate tab bar.
final class LoginViewController: UIViewController {

    private let app: RailCommerce
    private let biometricAuth: BiometricAuthProvider = FakeBiometricAuth()

    // Simulated user registry — replaced by a real auth backend in production.
    private let users: [String: User] = [
        "customer":  User(id: "C1", displayName: "Alice Rider",  role: .customer),
        "agent":     User(id: "A1", displayName: "Sam Agent",    role: .salesAgent),
        "editor":    User(id: "E1", displayName: "Eve Editor",   role: .contentEditor),
        "reviewer":  User(id: "R1", displayName: "Rita Review",  role: .contentReviewer),
        "csr":       User(id: "S1", displayName: "Chris CSR",    role: .customerService),
        "admin":     User(id: "D1", displayName: "Dan Admin",    role: .administrator)
    ]

    init(app: RailCommerce) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
    }

    // MARK: - UI

    private func setupUI() {
        let titleLabel = UILabel()
        titleLabel.text = "RailCommerce"
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.textAlignment = .center

        let subtitleLabel = UILabel()
        subtitleLabel.text = "Offline Ticket & Merchandise"
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textAlignment = .center
        subtitleLabel.textColor = .secondaryLabel

        let loginButton = UIButton(configuration: .filled())
        loginButton.setTitle("Sign In with Biometrics", for: .normal)
        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)

        let demoButton = UIButton(configuration: .tinted())
        demoButton.setTitle("Continue as Customer (Demo)", for: .normal)
        demoButton.addTarget(self, action: #selector(demoContinueTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, loginButton, demoButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])
    }

    // MARK: - Actions

    @objc private func loginTapped() {
        biometricAuth.authenticate(reason: "Sign in to RailCommerce") { [weak self] success in
            guard let self else { return }
            if success {
                // Default to customer role after biometric success.
                self.proceed(as: self.users["customer"]!)
            } else {
                let alert = UIAlertController(title: "Authentication Failed",
                                              message: "Could not verify your identity.",
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(alert, animated: true)
            }
        }
    }

    @objc private func demoContinueTapped() {
        proceed(as: users["customer"]!)
    }

    private func proceed(as user: User) {
        let tabBar = MainTabBarController(app: app, currentUser: user)
        tabBar.modalPresentationStyle = .fullScreen
        present(tabBar, animated: true)
    }
}
#endif
