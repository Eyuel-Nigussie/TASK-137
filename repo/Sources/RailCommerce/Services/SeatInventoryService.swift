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
    case persistenceFailed
}

/// Serializable pair used to persist seat states via `PersistenceStore`.
struct PersistedSeatState: Codable {
    let key: SeatKey
    let state: SeatState
}

/// Serializable reservation used to persist active reservations via `PersistenceStore`.
struct PersistedReservation: Codable {
    let reservation: Reservation
}

/// Serializable full-day inventory snapshot used for audit rollback persistence.
struct PersistedSnapshot: Codable {
    let date: String
    let entries: [PersistedSeatState]
}

public final class SeatInventoryService {
    public static let reservationLockSeconds: TimeInterval = 15 * 60
    public static let statesPrefix = "seat.state."
    public static let reservationsPrefix = "seat.res."
    public static let snapshotsPrefix = "seat.snap."

    private let clock: any Clock
    private let persistence: PersistenceStore?
    private let logger: Logger
    private var states: [SeatKey: SeatState] = [:]
    private var reservations: [SeatKey: Reservation] = [:]
    private var snapshots: [String: [SeatKey: SeatState]] = [:] // date → states
    private var lastSnapshotDate: String?

    /// Error from the most recent implicit durability write (e.g. the expiration
    /// sweep triggered by a `state(_:)` or `reservation(_:)` read). `nil` means
    /// the last implicit write succeeded. Callers that care about durability
    /// health — typically the background-task host — can poll this between
    /// reads. Explicit mutators always throw on failure; this is only for the
    /// implicit read-triggered path where throwing would cascade across the API.
    public private(set) var lastSweepError: Error?

    private let _events = PublishSubject<SeatInventoryEvent>()
    /// Observable stream of seat inventory events.
    public var events: Observable<SeatInventoryEvent> { _events.asObservable() }

    public init(clock: any Clock,
                persistence: PersistenceStore? = nil,
                logger: Logger = SilentLogger()) {
        self.clock = clock
        self.persistence = persistence
        self.logger = logger
        hydrate()
    }

    /// Registers a seat as available. Requires `actingUser` to hold
    /// `.manageInventory` (sales agents / admin) — registering baseline
    /// inventory is an administrative operation that must not be reachable
    /// from customer code paths.
    public func registerSeat(_ key: SeatKey, actingUser: User) throws {
        try RolePolicy.enforce(user: actingUser, .manageInventory)
        registerSeat(key)
    }

    /// Unchecked variant for internal composition + test fixtures (tests access
    /// via `@testable import`). External call sites must route through
    /// `registerSeat(_:actingUser:)` so `.manageInventory` is always enforced
    /// at the trust boundary.
    internal func registerSeat(_ key: SeatKey) {
        let prior = states[key]
        states[key] = .available
        do {
            try persistStates()
        } catch {
            if let prior { states[key] = prior }
            else { states.removeValue(forKey: key) }
            logger.error(.inventory, "registerSeat persist failed seat=\(key.seatNumber) err=\(error)")
        }
    }

    /// Returns all registered seat keys, sorted for stable ordering.
    public func registeredKeys() -> [SeatKey] {
        sweepExpired()
        return states.keys.sorted {
            ($0.trainId, $0.date, $0.segmentId, $0.seatClass.rawValue, $0.seatNumber) <
            ($1.trainId, $1.date, $1.segmentId, $1.seatClass.rawValue, $1.seatNumber)
        }
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
    /// - Parameter actingUser: Must hold `.purchase` or `.processTransaction`; otherwise `AuthorizationError.forbidden` is thrown.
    @discardableResult
    public func reserve(_ key: SeatKey, holderId: String, actingUser: User) throws -> Reservation {
        guard RolePolicy.can(actingUser.role, .purchase)
           || RolePolicy.can(actingUser.role, .processTransaction) else {
            logger.warn(.inventory, "reserve forbidden role=\(actingUser.role.rawValue)")
            throw AuthorizationError.forbidden(required: .purchase)
        }
        sweepExpired()
        guard let s = states[key] else { throw SeatError.unknownSeat }
        guard s == .available else { throw SeatError.notAvailable }
        let expires = clock.now().addingTimeInterval(Self.reservationLockSeconds)
        let res = Reservation(seat: key, holderId: holderId, expiresAt: expires)
        let prevState = states[key]
        let prevReservation = reservations[key]
        states[key] = .reserved
        reservations[key] = res
        do {
            try persistStates()
            try persistReservations()
        } catch {
            // Roll back in-memory mutation so the service does not report a
            // successful reservation that was never durably recorded.
            states[key] = prevState
            if let prev = prevReservation { reservations[key] = prev }
            else { reservations.removeValue(forKey: key) }
            throw error
        }
        _events.onNext(.seatReserved(key.trainId, key.seatNumber))
        logger.info(.inventory, "reserve seat=\(key.seatNumber) holder=\(holderId)")
        return res
    }

    /// Releases a reserved seat back to the available pool.
    ///
    /// Authorization is two-layered, mirroring `reserve` and `confirm`:
    /// 1. Function-level: caller must hold `.purchase` or `.processTransaction`.
    /// 2. Object-level: `holderId` must match the reservation's holder — unless
    ///    the caller holds `.processTransaction` (sales agent acting on behalf
    ///    of a customer). Customers can only release their own holds.
    public func release(_ key: SeatKey, holderId: String, actingUser: User) throws {
        guard RolePolicy.can(actingUser.role, .purchase)
           || RolePolicy.can(actingUser.role, .processTransaction) else {
            logger.warn(.inventory, "release forbidden role=\(actingUser.role.rawValue)")
            throw AuthorizationError.forbidden(required: .purchase)
        }
        guard let res = reservations[key] else { throw SeatError.notReserved }
        // Non-agents can only release reservations they hold.
        if !RolePolicy.can(actingUser.role, .processTransaction)
           && actingUser.id != holderId {
            logger.warn(.inventory, "release identityMismatch actor=\(actingUser.id) holder=\(holderId)")
            throw SeatError.wrongHolder
        }
        guard res.holderId == holderId else { throw SeatError.wrongHolder }
        let prevState = states[key]
        let prevReservation = reservations[key]
        reservations.removeValue(forKey: key)
        states[key] = .available
        do {
            try persistStates()
            try persistReservations()
        } catch {
            states[key] = prevState
            if let prev = prevReservation { reservations[key] = prev }
            throw error
        }
        _events.onNext(.seatReleased(key.trainId, key.seatNumber))
        logger.info(.inventory, "release seat=\(key.seatNumber) holder=\(holderId) actor=\(actingUser.id)")
    }

    /// Confirms a reserved seat, transitioning it to `sold`.
    /// - Parameter actingUser: Must hold `.purchase` or `.processTransaction`; otherwise `AuthorizationError.forbidden` is thrown.
    public func confirm(_ key: SeatKey, holderId: String, actingUser: User) throws {
        guard RolePolicy.can(actingUser.role, .purchase)
           || RolePolicy.can(actingUser.role, .processTransaction) else {
            logger.warn(.inventory, "confirm forbidden role=\(actingUser.role.rawValue)")
            throw AuthorizationError.forbidden(required: .purchase)
        }
        sweepExpired()
        guard let res = reservations[key] else { throw SeatError.notReserved }
        guard res.holderId == holderId else { throw SeatError.wrongHolder }
        let prevState = states[key]
        let prevReservation = reservations[key]
        reservations.removeValue(forKey: key)
        states[key] = .sold
        do {
            try persistStates()
            try persistReservations()
        } catch {
            states[key] = prevState
            if let prev = prevReservation { reservations[key] = prev }
            throw error
        }
        _events.onNext(.seatConfirmed(key.trainId, key.seatNumber))
        logger.info(.inventory, "confirm seat=\(key.seatNumber) holder=\(holderId)")
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

    /// Takes a daily snapshot scoped to `actingUser`. Requires
    /// `.manageInventory` — snapshots are audit-rollback fixtures that only
    /// admin / sales-agent roles may create.
    public func snapshot(date: String, actingUser: User) throws {
        try RolePolicy.enforce(user: actingUser, .manageInventory)
        try snapshot(date: date)
    }

    /// Takes a daily snapshot keyed by the supplied date string. Persisted so it
    /// survives app restarts and can drive audit rollbacks across sessions.
    /// Throws `SeatError.persistenceFailed` on durability failure after rolling
    /// back the in-memory snapshot entry — callers must not believe a snapshot
    /// was taken that the next `rollback(to:)` cannot restore from.
    /// Internal: production call sites must use `snapshot(date:actingUser:)`
    /// so `.manageInventory` authorization is enforced.
    internal func snapshot(date: String) throws {
        let priorSnapshot = snapshots[date]
        let priorLastDate = lastSnapshotDate
        snapshots[date] = states
        lastSnapshotDate = date
        do {
            try persistSnapshot(date: date)
        } catch {
            snapshots[date] = priorSnapshot
            lastSnapshotDate = priorLastDate
            logger.error(.inventory, "snapshot persist failed date=\(date) err=\(error)")
            throw error
        }
    }

    public func availableSnapshots() -> [String] { snapshots.keys.sorted() }

    /// Audit-rollback scoped to `actingUser`. Requires `.manageInventory`
    /// — rollback discards live reservations, so only admin / sales-agent
    /// roles may invoke it.
    public func rollback(to date: String, actingUser: User) throws {
        try RolePolicy.enforce(user: actingUser, .manageInventory)
        try rollback(to: date)
    }

    /// Restores seat state from the snapshot for `date`, enabling audit rollbacks.
    /// The restored state is persisted via `persistStates()` so the rollback
    /// survives restart. On durability failure the in-memory state is restored
    /// to its pre-rollback values and the error is propagated — callers must
    /// not believe an audit rollback succeeded that was never durably recorded.
    /// Internal: production call sites must use `rollback(to:actingUser:)`
    /// so `.manageInventory` authorization is enforced.
    internal func rollback(to date: String) throws {
        guard let snap = snapshots[date] else { throw SeatError.unknownSeat }
        let prevStates = states
        let prevReservations = reservations
        states = snap
        reservations.removeAll()
        do {
            try persistStates()
            try persistReservations()
        } catch {
            states = prevStates
            reservations = prevReservations
            throw error
        }
    }

    /// Expires any reservations whose hold has elapsed. If the resulting
    /// durable write fails, the in-memory expiration is rolled back so the
    /// next sweep retries rather than leaving the cache divergent from disk.
    /// Logs a structured failure in the `inventory` category and records the
    /// error on `lastSweepError` so callers can poll durability health even
    /// though sweep itself is invoked implicitly from non-throwing readers.
    private func sweepExpired() {
        let now = clock.now()
        let prevStates = states
        let prevReservations = reservations
        var anyExpired = false
        for (key, res) in reservations where res.expiresAt <= now {
            reservations.removeValue(forKey: key)
            if states[key] == .reserved { states[key] = .available }
            anyExpired = true
        }
        guard anyExpired else { return }
        do {
            try persistStates()
            try persistReservations()
            lastSweepError = nil
        } catch {
            states = prevStates
            reservations = prevReservations
            lastSweepError = error
            logger.error(.inventory, "sweepExpired persist failed err=\(error)")
        }
    }

    // MARK: - Persistence

    private func persistStates() throws {
        guard let persistence else { return }
        do {
            // Clear and re-write — a single batch since seat state is fully in memory.
            try persistence.deleteAll(prefix: Self.statesPrefix)
            let encoder = JSONEncoder()
            for (key, state) in states {
                let payload = PersistedSeatState(key: key, state: state)
                let data = try encoder.encode(payload)
                try persistence.save(key: Self.statesPrefix + stableKey(key), data: data)
            }
        } catch {
            logger.error(.inventory, "persistStates failed err=\(error)")
            throw SeatError.persistenceFailed
        }
    }

    private func persistReservations() throws {
        guard let persistence else { return }
        do {
            try persistence.deleteAll(prefix: Self.reservationsPrefix)
            let encoder = JSONEncoder()
            for (key, res) in reservations {
                let payload = PersistedReservation(reservation: res)
                let data = try encoder.encode(payload)
                try persistence.save(key: Self.reservationsPrefix + stableKey(key), data: data)
            }
        } catch {
            logger.error(.inventory, "persistReservations failed err=\(error)")
            throw SeatError.persistenceFailed
        }
    }

    /// Persists the snapshot for `date` under the snapshot prefix so daily
    /// audit snapshots survive process restarts.
    private func persistSnapshot(date: String) throws {
        guard let persistence else { return }
        guard let snap = snapshots[date] else { return }
        do {
            let entries = snap.map { PersistedSeatState(key: $0.key, state: $0.value) }
            let payload = PersistedSnapshot(date: date, entries: entries)
            let data = try JSONEncoder().encode(payload)
            try persistence.save(key: Self.snapshotsPrefix + date, data: data)
        } catch {
            logger.error(.inventory, "persistSnapshot failed date=\(date) err=\(error)")
            throw SeatError.persistenceFailed
        }
    }

    private func hydrate() {
        guard let persistence else { return }
        let decoder = JSONDecoder()
        do {
            for entry in try persistence.loadAll(prefix: Self.statesPrefix) {
                if let payload = try? decoder.decode(PersistedSeatState.self, from: entry.data) {
                    states[payload.key] = payload.state
                }
            }
            for entry in try persistence.loadAll(prefix: Self.reservationsPrefix) {
                if let payload = try? decoder.decode(PersistedReservation.self, from: entry.data) {
                    reservations[payload.reservation.seat] = payload.reservation
                }
            }
            // Rebuild the snapshots dictionary so rollback works post-restart.
            for entry in try persistence.loadAll(prefix: Self.snapshotsPrefix) {
                if let payload = try? decoder.decode(PersistedSnapshot.self, from: entry.data) {
                    var snap: [SeatKey: SeatState] = [:]
                    for e in payload.entries { snap[e.key] = e.state }
                    snapshots[payload.date] = snap
                    lastSnapshotDate = payload.date
                }
            }
        } catch {
            logger.error(.inventory, "hydrate failed err=\(error)")
        }
    }

    /// Builds a stable per-seat key for the persistence layer. Deterministic across
    /// runs so save + hydrate round-trips cleanly.
    private func stableKey(_ k: SeatKey) -> String {
        "\(k.trainId)|\(k.date)|\(k.segmentId)|\(k.seatClass.rawValue)|\(k.seatNumber)"
    }
}
