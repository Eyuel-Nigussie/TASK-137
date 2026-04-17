import Foundation

/// Binds biometric unlock to the last password-authenticated username.
///
/// Closes an account-takeover vector on shared devices where a device-owner's
/// biometric credential could unlock any known account simply by typing that
/// account's username. After this binding, biometric sign-in works only for the
/// username most recently verified through the password path; switching accounts
/// requires explicit password re-entry.
public enum BiometricBoundAccount {
    public static let keychainKey = "railcommerce.auth.boundUsername"

    /// Persists `username` as the sole account that biometric unlock may authenticate.
    /// Called from the password-verified path after `CredentialStore.verify` succeeds.
    public static func bind(_ username: String, in keychain: SecureStore) {
        let normalized = username.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty, let data = normalized.data(using: .utf8) else { return }
        try? keychain.set(data, forKey: keychainKey)
    }

    /// Returns the bound username, or `nil` if no password login has succeeded on this device.
    public static func current(in keychain: SecureStore) -> String? {
        guard let data = keychain.get(keychainKey),
              let username = String(data: data, encoding: .utf8),
              !username.isEmpty else { return nil }
        return username
    }

    /// Clears the binding (e.g. sign-out or explicit "forget this device" action).
    public static func clear(in keychain: SecureStore) {
        try? keychain.delete(keychainKey)
    }

    /// Validates a biometric unlock attempt. Returns the user the unlock should
    /// authenticate as, or `nil` if the attempt must be rejected.
    ///
    /// - Parameters:
    ///   - typedUsername: Optional username visible in the login field. If empty
    ///     or equal to the bound username, the bound user is returned. If it
    ///     differs, the unlock is rejected so biometrics cannot switch accounts.
    ///   - keychain: The secure store holding the bound username.
    ///   - credentialLookup: Resolves the bound username to a `User` via the
    ///     credential store.
    public static func resolveUnlock(
        typedUsername: String,
        keychain: SecureStore,
        credentialLookup: (String) -> User?
    ) -> User? {
        guard let bound = current(in: keychain) else { return nil }
        let typed = typedUsername.lowercased().trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty && typed != bound { return nil }
        return credentialLookup(bound)
    }
}
