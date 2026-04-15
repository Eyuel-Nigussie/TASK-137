#if canImport(UIKit)
import UIKit
import RailCommerce

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    /// The shared dependency container wired with production implementations.
    private(set) lazy var app: RailCommerce = {
        RailCommerce(
            clock: SystemClock(),
            keychain: InMemoryKeychain(),   // Replace with a SecureEnclave-backed store in production
            camera: FakeCamera(granted: true),
            battery: FakeBattery()
        )
    }()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = LoginViewController(app: app)
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
#endif
