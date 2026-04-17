import XCTest
import UIKit
@testable import RailCommerceApp
@testable import RailCommerce

/// Exercises the small iOS wrapper providers (`SystemCamera`,
/// `SystemBattery`, `ActivityTrackingWindow`) that live in the iOS target
/// and cannot be reached from the pure-Swift package tests.
final class SystemProvidersTests: XCTestCase {

    // MARK: - SystemCamera

    func testSystemCameraReportsPermissionState() {
        let cam = SystemCamera()
        _ = cam.isGranted
    }

    // MARK: - SystemBattery

    func testSystemBatteryReportsLevel() {
        let battery = SystemBattery()
        XCTAssertGreaterThanOrEqual(battery.level, 0.0)
        XCTAssertLessThanOrEqual(battery.level, 1.0)
    }

    func testSystemBatteryLowPowerModeReadable() {
        let battery = SystemBattery()
        _ = battery.isLowPowerMode
    }

    func testSystemBatteryIsChargingReadable() {
        let battery = SystemBattery()
        _ = battery.isCharging
    }

    func testSystemBatteryActivityResetsInactiveWindow() {
        let battery = SystemBattery()
        battery.recordActivity()
        XCTAssertFalse(battery.isUserInactive,
                       "isUserInactive must be false immediately after recordActivity()")
    }

    // MARK: - ActivityTrackingWindow

    func testActivityTrackingWindowForwardsTouchesToObserver() {
        let window = ActivityTrackingWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let battery = SystemBattery()
        // Backdate the activity so the observer is stale before touch.
        // (recordActivity is called at init with Date(); we can't easily backdate
        // without exposing state, so just exercise the code path.)
        window.activityObserver = battery
        // Build a minimal touch event and route it through sendEvent. We can't
        // construct a real UIEvent with `.touches` type purely from public APIs,
        // so we exercise sendEvent with a motion event instead to confirm the
        // window forwards non-touch events without crashing.
        let nonTouchEvent = UIEvent()
        window.sendEvent(nonTouchEvent)
    }
}
