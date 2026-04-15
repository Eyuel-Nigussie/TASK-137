import Foundation

/// Helper for computing business-hour deadlines used in SLA tracking.
/// Business day: Monday-Friday, 09:00-17:00 local (UTC for determinism).
public struct BusinessTime {
    public static let startHour = 9
    public static let endHour = 17

    public static func isBusinessDay(_ date: Date, calendar: Calendar = .utc) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        // 1 = Sunday, 7 = Saturday in Gregorian
        return weekday != 1 && weekday != 7
    }

    public static func isWithinBusinessHours(_ date: Date, calendar: Calendar = .utc) -> Bool {
        guard isBusinessDay(date, calendar: calendar) else { return false }
        let hour = calendar.component(.hour, from: date)
        return hour >= startHour && hour < endHour
    }

    /// Add `hours` business hours to `start`.
    public static func add(businessHours hours: Int, to start: Date, calendar: Calendar = .utc) -> Date {
        precondition(hours >= 0)
        var remaining = hours
        var cursor = clampToBusinessWindow(start, calendar: calendar)
        while remaining > 0 {
            let endOfDay = calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: cursor)!
            let hoursLeftToday = Int(endOfDay.timeIntervalSince(cursor) / 3600)
            if remaining <= hoursLeftToday {
                cursor = cursor.addingTimeInterval(TimeInterval(remaining) * 3600)
                remaining = 0
            } else {
                remaining -= hoursLeftToday
                cursor = nextBusinessDayStart(after: cursor, calendar: calendar)
            }
        }
        return cursor
    }

    /// Add `days` business days to `start` (retaining time-of-day when possible).
    public static func add(businessDays days: Int, to start: Date, calendar: Calendar = .utc) -> Date {
        precondition(days >= 0)
        var cursor = start
        var remaining = days
        while remaining > 0 {
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
            if isBusinessDay(cursor, calendar: calendar) { remaining -= 1 }
        }
        return cursor
    }

    private static func clampToBusinessWindow(_ date: Date, calendar: Calendar) -> Date {
        var cursor = date
        if !isBusinessDay(cursor, calendar: calendar) {
            cursor = nextBusinessDayStart(after: cursor, calendar: calendar)
            return cursor
        }
        let hour = calendar.component(.hour, from: cursor)
        if hour < startHour {
            cursor = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: cursor)!
        } else if hour >= endHour {
            cursor = nextBusinessDayStart(after: cursor, calendar: calendar)
        }
        return cursor
    }

    private static func nextBusinessDayStart(after date: Date, calendar: Calendar) -> Date {
        var cursor = calendar.date(byAdding: .day, value: 1, to: date)!
        cursor = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: cursor)!
        while !isBusinessDay(cursor, calendar: calendar) {
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        return cursor
    }
}

public extension Calendar {
    /// A Gregorian calendar fixed to UTC so tests and deadline math are deterministic
    /// regardless of the host timezone.
    static var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }
}
