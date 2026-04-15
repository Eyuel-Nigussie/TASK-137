import Foundation

/// Tracks cold-start time and memory-warning responses. On real iOS hardware the
/// harness would be wired to `applicationDidFinishLaunching` and `didReceiveMemoryWarning`.
public final class AppLifecycleService {
    public static let coldStartBudgetSeconds: TimeInterval = 1.5

    public private(set) var coldStartMillis: Int = 0
    public private(set) var cacheEvictions: Int = 0
    public private(set) var deferredDecodes: Int = 0
    public private(set) var memoryWarnings: Int = 0

    private let clock: Clock
    private var cache: [String: Data] = [:]
    private var pendingDecodes: [String] = []

    public init(clock: Clock) { self.clock = clock }

    /// Record a cold-start window. Returns whether the budget was met.
    @discardableResult
    public func markColdStart(begin: Date, end: Date) -> Bool {
        let elapsed = end.timeIntervalSince(begin)
        coldStartMillis = Int(elapsed * 1000)
        return elapsed < Self.coldStartBudgetSeconds
    }

    public func cache(key: String, data: Data) { cache[key] = data }
    public func cached(_ key: String) -> Data? { cache[key] }
    public func scheduleDecode(_ key: String) { pendingDecodes.append(key) }
    public var pendingDecodeKeys: [String] { pendingDecodes }

    /// Called when the system posts a memory warning. Evicts cache and defers heavy decodes.
    public func handleMemoryWarning() {
        memoryWarnings += 1
        cacheEvictions += cache.count
        cache.removeAll()
        deferredDecodes += pendingDecodes.count
        pendingDecodes.removeAll()
    }
}
