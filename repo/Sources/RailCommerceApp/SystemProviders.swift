#if canImport(UIKit)
import AVFoundation
import UIKit
import RailCommerce

/// Production camera permission implementation backed by `AVCaptureDevice`.
final class SystemCamera: CameraPermission {
    var isGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }
}

/// `UIWindow` subclass that pipes every touch event through
/// `SystemBattery.recordActivity()` so the "heavy work on power OR user
/// inactivity" gate in `ContentPublishingService` sees real UI interaction —
/// not just coarse `didBecomeActive` notifications. Install by using this
/// subclass as the app's root window.
final class ActivityTrackingWindow: UIWindow {
    /// Injected at AppDelegate launch time so every touch reports to the
    /// shared battery monitor. Weak to avoid a retain cycle.
    weak var activityObserver: SystemBattery?

    override func sendEvent(_ event: UIEvent) {
        if event.type == .touches {
            activityObserver?.recordActivity()
        }
        super.sendEvent(event)
    }
}

/// Production battery monitor backed by `UIDevice`, `ProcessInfo`, and a
/// touch-activity tracker for user-inactivity detection. Implements the full
/// `BatteryMonitor` protocol including `isCharging` and `isUserInactive` so
/// `ContentPublishingService` can enforce the "heavy work on power OR user
/// inactivity" contract from the prompt.
final class SystemBattery: BatteryMonitor {
    /// A scheduled publish / heavy-work job is considered safe to run after the
    /// user has been idle for this many seconds.
    static let inactivityThresholdSeconds: TimeInterval = 60

    private var lastActivityAt: Date = Date()

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        // Track touch activity at the app level so `isUserInactive` reflects
        // real UIKit touch state. Observing both "did become active" (resets
        // the timer) and a 1-second periodic tick via RunLoop is deliberately
        // avoided; the notification set below is sufficient.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.recordActivity() }
        NotificationCenter.default.addObserver(
            forName: UIApplication.significantTimeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.recordActivity() }
    }

    var level: Double {
        let raw = UIDevice.current.batteryLevel
        return raw < 0 ? 1.0 : Double(raw)   // –1 means unknown; treat as full
    }

    var isLowPowerMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// `UIDevice.batteryState` reports `.charging` or `.full` when the device is
    /// connected to external power. Both are treated as "on power" for the
    /// heavy-work gate. `.unknown` is treated as on power (device simulators
    /// often report unknown) so background tasks can still run under test.
    var isCharging: Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full, .unknown: return true
        case .unplugged: return false
        @unknown default: return true
        }
    }

    /// Considered inactive when no user interaction has been recorded in the
    /// last `inactivityThresholdSeconds` seconds. `AppDelegate` may call
    /// `recordActivity()` from a global touch-event hook to keep this live.
    var isUserInactive: Bool {
        Date().timeIntervalSince(lastActivityAt) >= Self.inactivityThresholdSeconds
    }

    func recordActivity() {
        lastActivityAt = Date()
    }
}
#endif
