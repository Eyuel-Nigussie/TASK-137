import XCTest
@testable import RailCommerce

/// Compile-time drift locks: each test target type below conforms to a
/// platform-boundary protocol whose iOS implementation (e.g. `SystemBattery`)
/// lives under `#if canImport(UIKit)` and thus **cannot be compiled on Linux
/// CI**. If anyone adds a new protocol requirement without a default, this
/// stand-in conformer breaks the test-target build, catching the drift that
/// the v5 audit flagged (`SystemBattery` missing `isCharging` / `isUserInactive`).
///
/// The tests below are runtime checks, but the *build* is the real assertion —
/// if any of these types fails to compile, the protocol has grown a new
/// requirement and every iOS-side conformer (SystemBattery, SystemCamera,
/// multipeer transport, etc.) must be updated in lockstep.

// MARK: - BatteryMonitor drift lock

/// Minimal conformer that satisfies every current `BatteryMonitor` requirement.
/// If a new required property is added, this type will fail to compile
/// (assertion: the Linux CI build breaks before shipping).
private final class LockBatteryMonitor: BatteryMonitor {
    var level: Double { 1.0 }
    var isLowPowerMode: Bool { false }
    var isCharging: Bool { true }
    var isUserInactive: Bool { true }
}

// MARK: - CameraPermission drift lock

private final class LockCameraPermission: CameraPermission {
    var isGranted: Bool { true }
}

// MARK: - SecureStore drift lock

private final class LockSecureStore: SecureStore {
    func set(_ value: Data, forKey key: String) throws {}
    func get(_ key: String) -> Data? { nil }
    func delete(_ key: String) throws {}
    func allKeys() -> [String] { [] }
    // seal / isSealed have protocol extensions, so they are optional.
}

// MARK: - PersistenceStore drift lock

private final class LockPersistenceStore: PersistenceStore {
    func save(key: String, data: Data) throws {}
    func load(key: String) throws -> Data? { nil }
    func loadAll(prefix: String) throws -> [(key: String, data: Data)] { [] }
    func delete(key: String) throws {}
    func deleteAll(prefix: String) throws {}
}

// MARK: - MessageTransport drift lock

private final class LockMessageTransport: MessageTransport {
    func send(_ message: Message) throws -> [String] { [] }
    func onReceive(_ handler: @escaping (Message) -> Void) {}
    func start(asPeer peerId: String) throws {}
    func stop() {}
    var connectedPeers: [String] { [] }
}

final class ProtocolConformanceDriftTests: XCTestCase {

    /// If any required `BatteryMonitor` property is added upstream without a
    /// default implementation, `LockBatteryMonitor` fails to compile — this
    /// test running at all proves the protocol surface is still satisfiable
    /// by just the properties this type declares.
    func testBatteryMonitorSurfaceIsFrozen() {
        let b = LockBatteryMonitor()
        XCTAssertEqual(b.level, 1.0)
        XCTAssertFalse(b.isLowPowerMode)
        XCTAssertTrue(b.isCharging)
        XCTAssertTrue(b.isUserInactive)
    }

    func testCameraPermissionSurfaceIsFrozen() {
        XCTAssertTrue(LockCameraPermission().isGranted)
    }

    func testSecureStoreSurfaceIsFrozen() throws {
        let s = LockSecureStore()
        try s.set(Data(), forKey: "k")
        XCTAssertNil(s.get("k"))
        XCTAssertTrue(s.allKeys().isEmpty)
    }

    func testPersistenceStoreSurfaceIsFrozen() throws {
        let p = LockPersistenceStore()
        try p.save(key: "k", data: Data())
        XCTAssertNil(try p.load(key: "k"))
        XCTAssertTrue(try p.loadAll(prefix: "x").isEmpty)
    }

    func testMessageTransportSurfaceIsFrozen() throws {
        let t = LockMessageTransport()
        try t.start(asPeer: "peer")
        XCTAssertTrue(t.connectedPeers.isEmpty)
        let msg = Message(id: "m", fromUserId: "a", toUserId: "b",
                          body: "hi", createdAt: Date())
        XCTAssertTrue(try t.send(msg).isEmpty)
    }

    /// `FakeBattery` must stay synchronized with the `BatteryMonitor` surface,
    /// since it's used by every content-publishing test and the composition
    /// root default. This sanity check prevents `FakeBattery` from drifting
    /// into an incomplete state during refactors.
    func testFakeBatteryExercisesEveryProperty() {
        let b = FakeBattery(level: 0.5, isLowPowerMode: true,
                            isCharging: false, isUserInactive: false)
        XCTAssertEqual(b.level, 0.5)
        XCTAssertTrue(b.isLowPowerMode)
        XCTAssertFalse(b.isCharging)
        XCTAssertFalse(b.isUserInactive)
    }
}
