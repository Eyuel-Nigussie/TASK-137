import XCTest
@testable import RailCommerce

final class SeatInventoryServiceTests: XCTestCase {
    private let customer = User(id: "c1", displayName: "Test Customer", role: .customer)
    private let salesAgent = User(id: "a1", displayName: "Test Agent", role: .salesAgent)

    private func makeService() -> (SeatInventoryService, FakeClock, SeatKey) {
        let clock = FakeClock()
        let svc = SeatInventoryService(clock: clock)
        let seat = SeatKey(trainId: "NE1", date: "2024-01-02", segmentId: "NY-BOS",
                           seatClass: .economy, seatNumber: "12A")
        svc.registerSeat(seat)
        return (svc, clock, seat)
    }

    func testReserveAndConfirm() throws {
        let (svc, _, seat) = makeService()
        // Sales agent on-behalf-of customer "H"; .processTransaction bypasses
        // the holder-identity binding, matching the audit report-2 fix.
        let res = try svc.reserve(seat, holderId: "H", actingUser: salesAgent)
        XCTAssertEqual(res.holderId, "H")
        XCTAssertEqual(svc.state(seat), .reserved)
        try svc.confirm(seat, holderId: "H", actingUser: salesAgent)
        XCTAssertEqual(svc.state(seat), .sold)
    }

    func testReserveRejectsUnknownSeat() {
        let (svc, _, _) = makeService()
        let unknown = SeatKey(trainId: "?", date: "?", segmentId: "?",
                              seatClass: .economy, seatNumber: "?")
        XCTAssertThrowsError(try svc.reserve(unknown, holderId: "H", actingUser: salesAgent)) { err in
            XCTAssertEqual(err as? SeatError, .unknownSeat)
        }
    }

    func testReserveRejectsNonAvailable() throws {
        let (svc, _, seat) = makeService()
        try svc.reserve(seat, holderId: "H1", actingUser: salesAgent)
        XCTAssertThrowsError(try svc.reserve(seat, holderId: "H2", actingUser: salesAgent)) { err in
            XCTAssertEqual(err as? SeatError, .notAvailable)
        }
    }

    func testReservationExpiresAfter15Minutes() throws {
        let (svc, clock, seat) = makeService()
        try svc.reserve(seat, holderId: "H", actingUser: salesAgent)
        clock.advance(by: 16 * 60)
        XCTAssertEqual(svc.state(seat), .available)
        XCTAssertNil(svc.reservation(seat))
    }

    func testReleaseReturnsToAvailable() throws {
        let (svc, _, seat) = makeService()
        try svc.reserve(seat, holderId: "H", actingUser: salesAgent)
        // Sales agents can release on behalf of any holder via .processTransaction.
        try svc.release(seat, holderId: "H", actingUser: salesAgent)
        XCTAssertEqual(svc.state(seat), .available)
    }

    func testReleaseByWrongHolder() throws {
        let (svc, _, seat) = makeService()
        try svc.reserve(seat, holderId: "H", actingUser: salesAgent)
        XCTAssertThrowsError(try svc.release(seat, holderId: "OTHER",
                                             actingUser: salesAgent)) { err in
            XCTAssertEqual(err as? SeatError, .wrongHolder)
        }
    }

    func testReleaseWithoutReservation() {
        let (svc, _, seat) = makeService()
        XCTAssertThrowsError(try svc.release(seat, holderId: "H",
                                             actingUser: salesAgent)) { err in
            XCTAssertEqual(err as? SeatError, .notReserved)
        }
    }

    func testReleaseForbiddenForNonPurchaseRole() throws {
        let (svc, _, seat) = makeService()
        try svc.reserve(seat, holderId: "H", actingUser: salesAgent)
        let editor = User(id: "e1", displayName: "E", role: .contentEditor)
        XCTAssertThrowsError(try svc.release(seat, holderId: "H",
                                             actingUser: editor)) { err in
            if case .forbidden = err as? AuthorizationError { /* expected */ }
            else { XCTFail("Expected AuthorizationError.forbidden for content editor") }
        }
    }

    /// Regression: customer acting user cannot release a reservation held by a
    /// different user — even if they guess the holder id.
    func testCustomerCannotReleaseOtherUsersReservation() throws {
        let (svc, _, seat) = makeService()
        try svc.reserve(seat, holderId: "c1", actingUser: customer)
        let otherCustomer = User(id: "c2", displayName: "Other", role: .customer)
        XCTAssertThrowsError(try svc.release(seat, holderId: "c1",
                                             actingUser: otherCustomer)) { err in
            XCTAssertEqual(err as? SeatError, .wrongHolder)
        }
        XCTAssertEqual(svc.state(seat), .reserved)
    }

    /// A customer CAN release their own reservation (actingUser.id == holderId).
    func testCustomerCanReleaseOwnReservation() throws {
        let (svc, _, seat) = makeService()
        try svc.reserve(seat, holderId: "c1", actingUser: customer)
        try svc.release(seat, holderId: "c1", actingUser: customer)
        XCTAssertEqual(svc.state(seat), .available)
    }

    func testConfirmWrongHolder() throws {
        let (svc, _, seat) = makeService()
        // Sales agent reserves on behalf of "H"; attempting to confirm with
        // a different holder still surfaces .wrongHolder on the reservation
        // match, independent of the identity-binding guard.
        try svc.reserve(seat, holderId: "H", actingUser: salesAgent)
        XCTAssertThrowsError(try svc.confirm(seat, holderId: "OTHER", actingUser: salesAgent)) { err in
            XCTAssertEqual(err as? SeatError, .wrongHolder)
        }
    }

    func testConfirmWithoutReservation() {
        let (svc, _, seat) = makeService()
        XCTAssertThrowsError(try svc.confirm(seat, holderId: "H", actingUser: salesAgent)) { err in
            XCTAssertEqual(err as? SeatError, .notReserved)
        }
    }

    func testAtomicRollsBackOnFailure() {
        let (svc, _, seat) = makeService()
        XCTAssertThrowsError(try svc.atomic {
            _ = try svc.reserve(seat, holderId: "H", actingUser: salesAgent)
            throw SeatError.notAvailable
        })
        XCTAssertEqual(svc.state(seat), .available)
        XCTAssertNil(svc.reservation(seat))
    }

    func testAtomicSucceeds() throws {
        let (svc, _, seat) = makeService()
        try svc.atomic {
            _ = try svc.reserve(seat, holderId: "H", actingUser: salesAgent)
        }
        XCTAssertEqual(svc.state(seat), .reserved)
    }

    func testSnapshotAndRollback() throws {
        let (svc, _, seat) = makeService()
        try svc.snapshot(date: "2024-01-01")
        try svc.reserve(seat, holderId: "H", actingUser: salesAgent)
        XCTAssertEqual(svc.state(seat), .reserved)
        try svc.rollback(to: "2024-01-01")
        XCTAssertEqual(svc.state(seat), .available)
        XCTAssertEqual(svc.availableSnapshots(), ["2024-01-01"])
    }

    func testRollbackUnknownSnapshot() {
        let (svc, _, _) = makeService()
        XCTAssertThrowsError(try svc.rollback(to: "never")) { err in
            XCTAssertEqual(err as? SeatError, .unknownSeat)
        }
    }

    func testStateForUnknown() {
        let (svc, _, _) = makeService()
        let unknown = SeatKey(trainId: "?", date: "?", segmentId: "?",
                              seatClass: .first, seatNumber: "?")
        XCTAssertNil(svc.state(unknown))
    }

    func testSeatKeyRoundTrip() throws {
        let k = SeatKey(trainId: "T", date: "D", segmentId: "S",
                        seatClass: .first, seatNumber: "N")
        let data = try JSONEncoder().encode(k)
        XCTAssertEqual(try JSONDecoder().decode(SeatKey.self, from: data), k)
    }

    func testSeatClassAndStateRoundTrip() throws {
        for cls in SeatClass.allCases {
            let data = try JSONEncoder().encode(cls)
            XCTAssertEqual(try JSONDecoder().decode(SeatClass.self, from: data), cls)
        }
        for state in [SeatState.available, .reserved, .sold] {
            let data = try JSONEncoder().encode(state)
            XCTAssertEqual(try JSONDecoder().decode(SeatState.self, from: data), state)
        }
    }
}
