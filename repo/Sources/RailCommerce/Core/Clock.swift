import Foundation

/// Abstract clock to allow deterministic time in tests and services.
public protocol Clock {
    func now() -> Date
}

public final class SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

public final class FakeClock: Clock {
    private var current: Date
    public init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }
    public func now() -> Date { current }
    public func advance(by seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }
    public func set(_ date: Date) { current = date }
}
