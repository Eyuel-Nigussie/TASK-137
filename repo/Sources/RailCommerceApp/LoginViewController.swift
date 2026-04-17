#if canImport(UIKit)
import UIKit
import RailCommerce

/// Entry-point view controller. Authenticates via a `CredentialStore` (PBKDF2-SHA256
/// Keychain-backed hashes) then offers biometric unlock for subsequent logins.
///
/// Biometric sign-in binds to the **last successfully password-authenticated**
/// username (see `BiometricBoundAccount`) — it cannot authenticate an arbitrary
/// typed username even if that username exists in the credential store. This
/// closes a shared-device account-takeover vector where a device owner's
/// biometric could unlock any known account just by typing its username.
final class LoginViewController: UIViewController {

    private let app: RailCommerce
    private let credentials: CredentialStore
    private let biometricAuth: BiometricAuthProvider

    private var usernameField: UITextField!
    private var passwordField: UITextField!
    private var signInButton: UIButton!
    private var biometricButton: UIButton!
    private var enrollButton: UIButton!
    private var enrollLabel: UILabel!
    private var errorLabel: UILabel!

    init(app: RailCommerce, credentials: CredentialStore) {
        self.app = app
        self.credentials = credentials
        #if canImport(LocalAuthentication)
        self.biometricAuth = LocalBiometricAuth()
        #else
        self.biometricAuth = FakeBiometricAuth(available: false, succeeds: false)
        #endif
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
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits = .header

        let subtitleLabel = UILabel()
        subtitleLabel.text = "Offline Ticket & Merchandise"
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textAlignment = .center
        subtitleLabel.textColor = .secondaryLabel

        usernameField = UITextField()
        usernameField.placeholder = "Username"
        usernameField.borderStyle = .roundedRect
        usernameField.autocapitalizationType = .none
        usernameField.autocorrectionType = .no
        usernameField.returnKeyType = .next
        usernameField.font = .preferredFont(forTextStyle: .body)
        usernameField.adjustsFontForContentSizeCategory = true
        usernameField.accessibilityLabel = "Username"
        usernameField.delegate = self

        passwordField = UITextField()
        passwordField.placeholder = "Password"
        passwordField.borderStyle = .roundedRect
        passwordField.isSecureTextEntry = true
        passwordField.returnKeyType = .done
        passwordField.font = .preferredFont(forTextStyle: .body)
        passwordField.adjustsFontForContentSizeCategory = true
        passwordField.accessibilityLabel = "Password"
        passwordField.delegate = self

        errorLabel = UILabel()
        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textColor = .systemRed
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        // Live-region announce on error updates (iOS 17+). Before iOS 17 the
        // label still reads on focus but not automatically when hidden→visible.
        // (No deployment-target-16 equivalent exists, so this is best-effort.)

        signInButton = UIButton(configuration: .filled())
        signInButton.setTitle("Sign In", for: .normal)
        signInButton.accessibilityLabel = "Sign In"
        signInButton.addTarget(self, action: #selector(signInTapped), for: .touchUpInside)

        biometricButton = UIButton(configuration: .tinted())
        let biometricTitle = biometricAuth.isAvailable ? "Sign In with Face ID / Touch ID" : "Biometrics Unavailable"
        biometricButton.setTitle(biometricTitle, for: .normal)
        biometricButton.isEnabled = biometricAuth.isAvailable
        biometricButton.accessibilityLabel = biometricTitle
        biometricButton.addTarget(self, action: #selector(biometricTapped), for: .touchUpInside)

        // First-install bootstrap: when the credential store is empty (no admin
        // has been enrolled yet), surface a button that lets the first user on
        // the device create an administrator account. This keeps release builds
        // unlockable without compiling in default credentials.
        enrollLabel = UILabel()
        enrollLabel.text = "No accounts are set up on this device."
        enrollLabel.font = .preferredFont(forTextStyle: .footnote)
        enrollLabel.adjustsFontForContentSizeCategory = true
        enrollLabel.textColor = .secondaryLabel
        enrollLabel.textAlignment = .center
        enrollLabel.numberOfLines = 0

        enrollButton = UIButton(configuration: .tinted())
        enrollButton.setTitle("Create Administrator Account", for: .normal)
        enrollButton.accessibilityLabel = "Create Administrator Account"
        enrollButton.addTarget(self, action: #selector(enrollAdministratorTapped), for: .touchUpInside)

        let hasCredentials = credentials.hasAnyCredentials()
        enrollLabel.isHidden = hasCredentials
        enrollButton.isHidden = hasCredentials

        let stack = UIStackView(arrangedSubviews: [
            titleLabel, subtitleLabel,
            usernameField, passwordField,
            signInButton, biometricButton,
            enrollLabel, enrollButton,
            errorLabel
        ])
        stack.axis = .vertical
        stack.spacing = 12
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

    @objc private func signInTapped() {
        let username = (usernameField.text ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        let password = passwordField.text ?? ""
        authenticate(username: username, password: password)
    }

    @objc private func biometricTapped() {
        // Biometric unlock only works against the last password-authenticated account.
        // Any typed username that differs from the bound account is rejected so the
        // device owner's biometric cannot authenticate into an arbitrary account.
        guard BiometricBoundAccount.current(in: app.keychain) != nil else {
            showError("Sign in with your password first to enable biometric unlock.")
            return
        }
        let typed = usernameField.text ?? ""
        guard let boundUser = BiometricBoundAccount.resolveUnlock(
            typedUsername: typed,
            keychain: app.keychain,
            credentialLookup: { self.credentials.user(forUsername: $0) }
        ) else {
            // Intentionally do NOT echo the bound username — doing so would
            // leak which account is attached to this device biometric to a
            // bystander who is trying to sign in as a different user.
            showError("Biometric is bound to a different account. Enter that account's password to switch.")
            return
        }
        biometricAuth.authenticate(reason: "Sign in to RailCommerce") { [weak self] success in
            guard let self else { return }
            if success {
                self.proceed(as: boundUser)
            } else {
                self.showError("Biometric authentication failed.")
            }
        }
    }

    @objc private func enrollAdministratorTapped() {
        // Guard: the enrollment path is only available on first install, before
        // any credential has been stored. Re-check at tap time to close a race
        // where a background enrollment could land between view load and tap.
        guard !credentials.hasAnyCredentials() else {
            enrollLabel.isHidden = true
            enrollButton.isHidden = true
            showError("An account already exists on this device. Please sign in.")
            return
        }
        let form = UIAlertController(
            title: "Create Administrator",
            message: "Enter a username and a strong password (12+ chars, digit + symbol).",
            preferredStyle: .alert)
        form.addTextField {
            $0.placeholder = "Username"
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        form.addTextField {
            $0.placeholder = "Password"
            $0.isSecureTextEntry = true
        }
        form.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self,
                  let u = form.textFields?[0].text?
                    .lowercased().trimmingCharacters(in: .whitespaces),
                  let p = form.textFields?[1].text,
                  !u.isEmpty, !p.isEmpty else {
                self?.showError("Username and password are required.")
                return
            }
            let adminUser = User(id: "admin-" + UUID().uuidString.prefix(8).lowercased(),
                                 displayName: u,
                                 role: .administrator)
            do {
                try self.credentials.enroll(username: u, password: p, user: adminUser)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.enrollLabel.isHidden = true
                self.enrollButton.isHidden = true
                self.usernameField.text = u
                self.showError("Administrator created. Enter the password to sign in.")
            } catch CredentialError.weakPassword(let reason) {
                self.showError(reason)
            } catch CredentialError.usernameAlreadyEnrolled {
                self.showError("That username is already enrolled.")
            } catch {
                self.showError("Could not create administrator. Please try again.")
            }
        })
        form.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(form, animated: true)
    }

    // MARK: - Credential validation

    private func authenticate(username: String, password: String) {
        guard !username.isEmpty else { showError("Username is required."); return }
        guard !password.isEmpty else { showError("Password is required."); return }
        guard let user = credentials.verify(username: username, password: password) else {
            showError("Invalid username or password.")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        // Bind the biometric unlock to this verified account so a later biometric
        // sign-in can only authenticate into this specific user.
        BiometricBoundAccount.bind(username, in: app.keychain)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        proceed(as: user)
    }

    private func showError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
    }

    private func proceed(as user: User) {
        errorLabel.isHidden = true
        // Start transport with the user's ID so peer identifiers align with
        // the messaging identity model (toUserId matches peer display names).
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.startPeerTransport(asUser: user.id)
        }
        if let shell = AppShellFactory.makeShell(app: app, currentUser: user) {
            shell.modalPresentationStyle = .fullScreen
            present(shell, animated: true)
        }
    }
}

// MARK: - UITextFieldDelegate

extension LoginViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === usernameField {
            passwordField.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
            signInTapped()
        }
        return true
    }
}
#endif
