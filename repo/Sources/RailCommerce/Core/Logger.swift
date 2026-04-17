import Foundation

/// Logging categories. Keep this list closed so dashboards can reason over a fixed taxonomy.
public enum LogCategory: String, Sendable, CaseIterable {
    case auth
    case checkout
    case inventory
    case afterSales
    case messaging
    case content
    case persistence
    case transport
    case lifecycle
}

/// Structured logging abstraction used by every service. The iOS target wires a
/// `SystemLogger` backed by `os.Logger`; tests and Linux CI use `InMemoryLogger` or
/// `SilentLogger`.
public protocol Logger: AnyObject {
    /// Emit a debug-level record (verbose developer output).
    func debug(_ category: LogCategory, _ message: String)
    /// Emit an info-level record (normal lifecycle transitions).
    func info(_ category: LogCategory, _ message: String)
    /// Emit a warn-level record (policy rejection, authorization failure, validation error).
    func warn(_ category: LogCategory, _ message: String)
    /// Emit an error-level record (unexpected failure that needs investigation).
    func error(_ category: LogCategory, _ message: String)
}

/// Alias for `Logger` that does NOT conflict with `os.Logger` when a caller
/// imports both `os` and this module — typical in the iOS app target that
/// wires a `SystemLogger` backed by `os.Logger`. Always prefer `RCLogger` when
/// a file also imports `os`.
public typealias RCLogger = Logger

/// Emitted record captured by `InMemoryLogger` for test assertions.
public struct LogRecord: Equatable, Sendable {
    public enum Level: String, Sendable { case debug, info, warn, error }
    public let level: Level
    public let category: LogCategory
    public let message: String
    public let at: Date
}

/// Default silent logger — used when callers don't supply one. Zero allocations.
public final class SilentLogger: Logger {
    public init() {}
    public func debug(_ category: LogCategory, _ message: String) {}
    public func info(_ category: LogCategory, _ message: String) {}
    public func warn(_ category: LogCategory, _ message: String) {}
    public func error(_ category: LogCategory, _ message: String) {}
}

/// Test-visible logger that retains all records in memory.
public final class InMemoryLogger: Logger {
    private let clock: any Clock
    private(set) public var records: [LogRecord] = []

    public init(clock: any Clock = SystemClock()) { self.clock = clock }

    public func debug(_ category: LogCategory, _ message: String) { append(.debug, category, message) }
    public func info(_ category: LogCategory, _ message: String)  { append(.info, category, message) }
    public func warn(_ category: LogCategory, _ message: String)  { append(.warn, category, message) }
    public func error(_ category: LogCategory, _ message: String) { append(.error, category, message) }

    /// Returns only records matching `category`.
    public func records(in category: LogCategory) -> [LogRecord] {
        records.filter { $0.category == category }
    }

    /// Returns only records at `level`.
    public func records(at level: LogRecord.Level) -> [LogRecord] {
        records.filter { $0.level == level }
    }

    public func clear() { records.removeAll() }

    private func append(_ level: LogRecord.Level, _ category: LogCategory, _ message: String) {
        records.append(LogRecord(level: level, category: category,
                                 message: LogRedactor.redact(message), at: clock.now()))
    }
}

/// Central sensitive-field redactor applied to every log message before persistence.
/// This layer is the last line of defense against accidental PII leakage into logs.
public enum LogRedactor {
    /// Email → `[email]`, US SSN → `[ssn]`, 13-19 digit sequences (payment cards) → `[card]`,
    /// US phone numbers → `[phone]`.
    public static func redact(_ message: String) -> String {
        var out = message
        let patterns: [(String, String)] = [
            ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "[email]"),
            ("\\b\\d{3}-\\d{2}-\\d{4}\\b", "[ssn]"),
            ("\\b(?:\\d[ -]*?){13,19}\\b", "[card]"),
            ("\\(?\\d{3}\\)?[-. ]?\\d{3}[-. ]?\\d{4}", "[phone]")
        ]
        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = regex.stringByReplacingMatches(in: out, options: [], range: range,
                                                 withTemplate: replacement)
        }
        return out
    }
}
