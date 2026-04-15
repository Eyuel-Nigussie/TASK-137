import Foundation

/// Abstraction over `LocalAuthentication` so business logic and tests can run on any platform.
public protocol BiometricAuthProvider {
    /// `true` when the device can evaluate biometric or device-passcode policies.
    var isAvailable: Bool { get }
    /// Runs the authentication dialog asynchronously and calls `completion(success)`.
    func authenticate(reason: String, completion: @escaping (Bool) -> Void)
}

/// Test double: always returns the values you configure at construction time.
public final class FakeBiometricAuth: BiometricAuthProvider {
    public var isAvailable: Bool
    private let succeeds: Bool

    public init(available: Bool = true, succeeds: Bool = true) {
        self.isAvailable = available
        self.succeeds = succeeds
    }

    public func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        completion(succeeds)
    }
}

#if canImport(LocalAuthentication)
import LocalAuthentication

/// Production implementation backed by `LAContext`. iOS / macOS only.
public final class LocalBiometricAuth: BiometricAuthProvider {
    public init() {}

    public var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    public func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        let ctx = LAContext()
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    }
}
#endif
