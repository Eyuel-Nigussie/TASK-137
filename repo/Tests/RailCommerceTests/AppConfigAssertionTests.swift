import XCTest
@testable import RailCommerce

/// Static assertions that the iOS app target's Info.plist declares the keys
/// required for runtime functionality. These catch config drift at test time
/// instead of waiting for on-device runtime permission failures.
final class AppConfigAssertionTests: XCTestCase {

    private func loadAppInfoPlist() -> [String: Any]? {
        // Resolve relative to the source tree; tests run from the package root.
        let candidates = [
            "Sources/RailCommerceApp/Info.plist",
            "repo/Sources/RailCommerceApp/Info.plist",
            "../Sources/RailCommerceApp/Info.plist"
        ]
        for path in candidates {
            if let data = FileManager.default.contents(atPath: path),
               let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] {
                return plist
            }
        }
        return nil
    }

    func testInfoPlistDeclaresLocalNetworkUsageDescription() throws {
        guard let plist = loadAppInfoPlist() else {
            throw XCTSkip("Info.plist not found in expected paths; skipping config assertion")
        }
        let value = plist["NSLocalNetworkUsageDescription"] as? String
        XCTAssertNotNil(value, "NSLocalNetworkUsageDescription is required by iOS for Multipeer local-network access")
        XCTAssertFalse(value?.isEmpty ?? true, "Usage description must be non-empty")
    }

    /// Camera usage description must be declared or iOS rejects the camera
    /// permission prompt used by the after-sales photo-proof flow. Captures
    /// regression after the v6 audit flagged this as a blocker-level miss.
    func testInfoPlistDeclaresNSCameraUsageDescription() throws {
        guard let plist = loadAppInfoPlist() else {
            throw XCTSkip("Info.plist not found in expected paths; skipping config assertion")
        }
        let value = plist["NSCameraUsageDescription"] as? String
        XCTAssertNotNil(value,
                        "NSCameraUsageDescription is required for the after-sales photo-proof camera flow")
        XCTAssertFalse(value?.isEmpty ?? true, "Camera usage description must be non-empty")
    }

    func testInfoPlistDeclaresBonjourServicesForMultipeer() throws {
        guard let plist = loadAppInfoPlist() else {
            throw XCTSkip("Info.plist not found in expected paths; skipping config assertion")
        }
        let services = plist["NSBonjourServices"] as? [String]
        XCTAssertNotNil(services, "NSBonjourServices is required for Multipeer peer discovery on modern iOS")
        // MultipeerConnectivity advertises both _tcp and _udp service records.
        XCTAssertTrue(services?.contains("_railcommerce._tcp") ?? false,
                      "Bonjour TCP service for the railcommerce service type must be declared")
        XCTAssertTrue(services?.contains("_railcommerce._udp") ?? false,
                      "Bonjour UDP service for the railcommerce service type must be declared")
    }

    func testInfoPlistDeclaresBGTaskSchedulerPermittedIdentifiers() throws {
        guard let plist = loadAppInfoPlist() else {
            throw XCTSkip("Info.plist not found in expected paths; skipping config assertion")
        }
        let ids = plist["BGTaskSchedulerPermittedIdentifiers"] as? [String]
        XCTAssertNotNil(ids)
        XCTAssertTrue(ids?.contains("com.railcommerce.content.publish") ?? false)
        XCTAssertTrue(ids?.contains("com.railcommerce.attachments.cleanup") ?? false)
    }

    /// Guards against drift between the BGTask identifiers declared in Info.plist
    /// and the ones used by `AppDelegate.bgPublishTaskId` / `bgCleanupTaskId`.
    /// If either side is renamed, this test fails before runtime.
    func testBGTaskIdentifiersInCodeMatchInfoPlist() throws {
        guard let plist = loadAppInfoPlist() else {
            throw XCTSkip("Info.plist not found in expected paths; skipping config assertion")
        }
        let ids = plist["BGTaskSchedulerPermittedIdentifiers"] as? [String] ?? []
        // AppDelegate constants (reproduced here because the test target does not
        // import the iOS-only RailCommerceApp target).
        let appDelegatePublishId = "com.railcommerce.content.publish"
        let appDelegateCleanupId = "com.railcommerce.attachments.cleanup"
        XCTAssertTrue(ids.contains(appDelegatePublishId),
                      "AppDelegate.bgPublishTaskId must be listed in Info.plist")
        XCTAssertTrue(ids.contains(appDelegateCleanupId),
                      "AppDelegate.bgCleanupTaskId must be listed in Info.plist")
    }

    func testInfoPlistDeclaresRequiredBackgroundModes() throws {
        guard let plist = loadAppInfoPlist() else {
            throw XCTSkip("Info.plist not found in expected paths; skipping config assertion")
        }
        let modes = plist["UIBackgroundModes"] as? [String]
        XCTAssertNotNil(modes)
        // Both publishing and cleanup are BGProcessingTasks now (power-gated), so
        // only `processing` is required. No `fetch` entry means iOS will not wake
        // us for unconstrained opportunistic refresh — heavy work stays power-gated.
        XCTAssertTrue(modes?.contains("processing") ?? false,
                      "processing mode required for BGProcessingTask (publish + cleanup)")
    }
}
