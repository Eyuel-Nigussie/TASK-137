import Foundation
import RxSwift

public enum SeatClass: String, Codable, CaseIterable, Sendable {
    case economy, business, first
}

public struct SeatKey: Hashable, Codable, Sendable {
    public let trainId: String
    public let date: String       // YYYY-MM-DD
    public let segmentId: String
    public let seatClass: SeatClass
    public let seatNumber: String

    public init(trainId: String, date: String, segmentId: String,
                seatClass: SeatClass, seatNumber: String) {
        self.trainId = trainId; self.date = date; self.segmentId = segmentId
        self.seatClass = seatClass; self.seatNumber = seatNumber
    }
}

public enum SeatState: String, Codable, Sendable {
    case available
    case reserved
    case sold
}

public struct Reservation: Codable, Equatable, Sendable {
    public let seat: SeatKey
    public let holderId: String
    public let expiresAt: Date
}

public enum SeatError: Error, Equatable {
    case unknownSeat
    case notAvailable
    case notReserved
    case reservationExpired
    case wrongHolder
}

public final class SeatInventoryService {
    public static let reservationLockSeconds: TimeInterval = 15 * 60

    private let clock: Clock
    private var states: [SeatKey: SeatState] = [:]
    private var reservations: [SeatKey: Reservation] = [:]
    private var snapshots: [String: [SeatKey: SeatState]] = [:] // date → states
    private var lastSnapshotDate: String?

    private let _events = PublishSubject<SeatInventoryEvent>()
    /// Observable stream of seat inventory events.
    public var events: Observable<SeatInventoryEvent> { _events.asObservable() }

    public init(clock: Clock) { self.clock = clock }

    public func registerSeat(_ key: SeatKey) {
        states[key] = .available
    }

    public func state(_ key: SeatKey) -> SeatState? {
        sweepExpired()
        return states[key]
    }

    public func reservation(_ key: SeatKey) -> Reservation? {
        sweepExpired()
        return reservations[key]
    }

    /// Atomically reserves a seat with a 15-minute hold.
    /// - Parameter actingUser: Must hold `.purchase` or `.processTransaction` when provided.
    @discardableResult
    public func reserve(_ key: SeatKey, holderId: String, actingUser: User? = nil) throws -> Reservation {
        if let user = actingUser,
           !RolePolicy.can(user.role, .purchase),
           !RolePolicy.can(user.role, .processTransaction) {
            throw AuthorizationError.forbidden(required: .purchase)
        }
        sweepExpired()
        guard let s = states[key] else { throw SeatError.unknownSeat }
        guard s == .available else { throw SeatError.notAvailable }
        let expires = clock.now().addingTimeInterval(Self.reservationLockSeconds)
        let res = Reservation(seat: key, holderId: holderId, expiresAt: expires)
        states[key] = .reserved
        reservations[key] = res
        _events.onNext(.seatReserved(key.trainId, key.seatNumber))
        return res
    }

    public func release(_ key: SeatKey, holderId: String) throws {
        guard let res = reservations[key] else { throw SeatError.notReserved }
        guard res.holderId == holderId else { throw SeatError.wrongHolder }
        reservations.removeValue(forKey: key)
        states[key] = .available
        _events.onNext(.seatReleased(key.trainId, key.seatNumber))
    }

    /// Confirms a reserved seat, transitioning it to `sold`.
    /// - Parameter actingUser: Must hold `.purchase` or `.processTransaction` when provided.
    public func confirm(_ key: SeatKey, holderId: String, actingUser: User? = nil) throws {
        if let user = actingUser,
           !RolePolicy.can(user.role, .purchase),
           !RolePolicy.can(user.role, .processTransaction) {
            throw AuthorizationError.forbidden(required: .purchase)
        }
        sweepExpired()
        guard let res = reservations[key] else { throw SeatError.notReserved }
        guard res.holderId == holderId else { throw SeatError.wrongHolder }
        reservations.removeValue(forKey: key)
        states[key] = .sold
        _events.onNext(.seatConfirmed(key.trainId, key.seatNumber))
    }

    /// Runs `work` as an atomic unit: if it throws, all mutations during the unit are rolled back.
    public func atomic<T>(_ work: () throws -> T) rethrows -> T {
        let backupStates = states
        let backupReservations = reservations
        do {
            return try work()
        } catch {
            states = backupStates
            reservations = backupReservations
            throw error
        }
    }

    /// Takes a daily snapshot keyed by the supplied date string.
    public func snapshot(date: String) {
        snapshots[date] = states
        lastSnapshotDate = date
    }

    public func availableSnapshots() -> [String] { snapshots.keys.sorted() }

    /// Restores seat state from the snapshot for `date`, enabling audit rollbacks.
    public func rollback(to date: String) throws {
        guard let snap = snapshots[date] else { throw SeatError.unknownSeat }
        states = snap
        reservations.removeAll()
    }

    private func sweepExpired() {
        let now = clock.now()
        for (key, res) in reservations where res.expiresAt <= now {
            reservations.removeValue(forKey: key)
            if states[key] == .reserved { states[key] = .available }
        }
    }
}
