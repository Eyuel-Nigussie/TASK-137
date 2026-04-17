import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Credential store abstraction. Replaces the plaintext, compiled-in login fixtures
/// that previously lived in `LoginViewController`.
///
/// Production implementations:
/// - `KeychainCredentialStore` (below) — persists per-user PBKDF2-SHA256 hashes into
///   a `SecureStore` (`InMemoryKeychain` in tests, `SystemKeychain` on iOS) with a
///   Keychain-held pepper that is generated once at first launch.
///
/// The protocol deliberately never exposes plaintext passwords after enrollment.
public protocol CredentialStore {
    /// Enroll a new user with a plaintext password. The implementation hashes the
    /// password and discards the plaintext. Throws if the username is already
    /// enrolled or the password does not satisfy the policy.
    func enroll(username: String, password: String, user: User) throws

    /// Verify a username/password pair against the stored hash.
    /// - Returns: The enrolled `User` on success; `nil` on unknown username or
    ///   password mismatch. Uses constant-time comparison.
    func verify(username: String, password: String) -> User?

    /// Returns the `User` enrolled for the username if present. Used by biometric
    /// sign-in, which validates identity through `LocalAuthentication` first and
    /// then looks up the mapped `User` record.
    func user(forUsername username: String) -> User?

    /// Remove a user from the store.
    func remove(username: String) throws

    /// Returns `true` if at least one credential is enrolled. Used by the UI to
    /// detect first-install state and offer an administrator enrollment flow so
    /// release builds are not locked out when no credentials have been seeded.
    func hasAnyCredentials() -> Bool
}

public extension CredentialStore {
    /// Default implementation preserves back-compat for callers that don't
    /// implement the first-install check directly; always returns `true` so
    /// unaware implementations don't accidentally open the bootstrap path.
    func hasAnyCredentials() -> Bool { true }
}

public enum CredentialError: Error, Equatable {
    case usernameAlreadyEnrolled
    case weakPassword(reason: String)
    case decodingFailed
    case pepperMissing
    case userNotFound
}

/// Minimum password policy. Enforced on enrollment. Reasons are returned as strings
/// so the UI can surface them verbatim.
public enum PasswordPolicy {
    public static func validate(_ password: String) -> String? {
        if password.count < 12 { return "Password must be at least 12 characters." }
        if password.range(of: "\\d", options: .regularExpression) == nil {
            return "Password must contain at least one digit."
        }
        let symbolClass = "[!@#$%^&*()_+\\-={}\\[\\]:;\"'<>,.?/|\\\\`~]"
        if password.range(of: symbolClass, options: .regularExpression) == nil {
            return "Password must contain at least one symbol."
        }
        return nil
    }
}

/// A stored credential entry. Persisted as JSON in `SecureStore`.
public struct StoredCredential: Codable, Equatable {
    public let username: String
    public let salt: Data          // 32 random bytes per user
    public let iterations: Int     // stored alongside hash for forward migration
    public let hash: Data          // PBKDF2-SHA256(password || pepper, salt, iterations, 32)
    public let user: User
}

/// Production credential store backed by a `SecureStore` (iOS Keychain in release,
/// `InMemoryKeychain` in tests). PBKDF2-SHA256 with 310_000 iterations and a 32-byte
/// pepper pulled from a Keychain item created once per install.
public final class KeychainCredentialStore: CredentialStore {
    public static let iterations = 310_000
    public static let hashBytes  = 32
    public static let saltBytes  = 32
    public static let pepperKey  = "railcommerce.credential.pepper"
    public static let credentialPrefix = "railcommerce.credential."

    private let keychain: SecureStore
    private let saltProvider: () -> Data

    /// - Parameter saltProvider: Injectable in tests so salt is deterministic; in
    ///   production defaults to 32 cryptographically random bytes.
    public init(keychain: SecureStore,
                saltProvider: @escaping () -> Data = {
                    KeychainCredentialStore.randomBytes(KeychainCredentialStore.saltBytes)
                }) {
        self.keychain = keychain
        self.saltProvider = saltProvider
        _ = try? ensurePepper()
    }

    // MARK: - CredentialStore

    public func enroll(username: String, password: String, user: User) throws {
        if let reason = PasswordPolicy.validate(password) {
            throw CredentialError.weakPassword(reason: reason)
        }
        let key = Self.credentialPrefix + username.lowercased()
        if keychain.get(key) != nil { throw CredentialError.usernameAlreadyEnrolled }
        let salt = saltProvider()
        let pepper = try ensurePepper()
        let hash = Self.pbkdf2(password: password, pepper: pepper,
                               salt: salt, iterations: Self.iterations)
        let entry = StoredCredential(username: username, salt: salt,
                                     iterations: Self.iterations, hash: hash, user: user)
        let data = try JSONEncoder().encode(entry)
        try keychain.set(data, forKey: key)
    }

    public func verify(username: String, password: String) -> User? {
        let key = Self.credentialPrefix + username.lowercased()
        guard let data = keychain.get(key),
              let entry = try? JSONDecoder().decode(StoredCredential.self, from: data),
              let pepper = try? ensurePepper() else { return nil }
        let computed = Self.pbkdf2(password: password, pepper: pepper,
                                   salt: entry.salt, iterations: entry.iterations)
        return Self.constantTimeEqual(computed, entry.hash) ? entry.user : nil
    }

    public func user(forUsername username: String) -> User? {
        let key = Self.credentialPrefix + username.lowercased()
        guard let data = keychain.get(key),
              let entry = try? JSONDecoder().decode(StoredCredential.self, from: data) else {
            return nil
        }
        return entry.user
    }

    public func remove(username: String) throws {
        let key = Self.credentialPrefix + username.lowercased()
        guard keychain.get(key) != nil else { throw CredentialError.userNotFound }
        try keychain.delete(key)
    }

    /// First-install detection: `true` once any credential has been enrolled,
    /// `false` when the keychain has no stored credentials. Drives the
    /// enrollment-path fallback in `LoginViewController` so release builds
    /// can bootstrap an administrator without needing a compiled-in seed.
    /// The pepper key shares the credential prefix but is not itself a
    /// credential, so it's explicitly excluded from this check.
    public func hasAnyCredentials() -> Bool {
        keychain.allKeys().contains { key in
            key.hasPrefix(Self.credentialPrefix) && key != Self.pepperKey
        }
    }

    // MARK: - Pepper management

    private func ensurePepper() throws -> Data {
        if let existing = keychain.get(Self.pepperKey) { return existing }
        let newPepper = Self.randomBytes(32)
        try keychain.set(newPepper, forKey: Self.pepperKey)
        keychain.seal(Self.pepperKey)
        return newPepper
    }

    // MARK: - Crypto helpers

    /// Constant-time byte comparison. Prevents timing-based credential discovery.
    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// PBKDF2-SHA256 implemented via CryptoKit's HMAC primitive. Pure Swift, no
    /// CommonCrypto dependency, so the core library stays platform-free.
    public static func pbkdf2(password: String, pepper: Data, salt: Data,
                              iterations: Int, length: Int = hashBytes) -> Data {
        #if canImport(CryptoKit)
        let passwordBytes = Array(password.utf8) + Array(pepper)
        let key = SymmetricKey(data: passwordBytes)

        var result = Data()
        var blockIndex: UInt32 = 1
        while result.count < length {
            var u = Data(salt)
            var blockBigEndian = blockIndex.bigEndian
            u.append(Data(bytes: &blockBigEndian, count: 4))
            var previous = Data(HMAC<CryptoKit.SHA256>.authenticationCode(for: u, using: key))
            var block = previous
            for _ in 1..<iterations {
                let current = Data(HMAC<CryptoKit.SHA256>.authenticationCode(for: previous, using: key))
                for i in 0..<block.count { block[i] ^= current[i] }
                previous = current
            }
            result.append(block)
            blockIndex += 1
        }
        return result.prefix(length)
        #else
        // Non-Apple fallback: SHA-256 iterated hash via the pure-Swift module SHA256.
        // Weaker than PBKDF2 but keeps the Linux build working for CI.
        var acc = Data(password.utf8) + pepper + salt
        for _ in 0..<iterations { acc = SHA256.digest(acc) }
        return acc.prefix(length)
        #endif
    }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        #if canImport(Security)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        #else
        for i in 0..<count { bytes[i] = UInt8.random(in: 0...UInt8.max) }
        #endif
        return Data(bytes)
    }
}
