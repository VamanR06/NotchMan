import Foundation

/// Parses the ISO 8601 / RFC 3339 dates used by web APIs (Google, Notion).
public enum DateParsing {
    // Date formatters are thread-safe for formatting and parsing.
    nonisolated(unsafe) private static let internet: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Parses `2026-10-20`, `2026-10-20T10:00:00-04:00`, or with fractional seconds.
    /// Returns the date and whether it was a date-only (all-day) value.
    public static func parse(_ string: String) -> (Date, isAllDay: Bool)? {
        if string.count == 10, let d = dayOnly.date(from: string) { return (d, true) }
        if let d = internet.date(from: string) ?? fractional.date(from: string) { return (d, false) }
        return nil
    }

    public static func rfc3339(_ date: Date) -> String {
        internet.string(from: date)
    }

    /// `2026-10-22` in the local time zone (all-day dates).
    public static func dayString(_ date: Date) -> String {
        dayOnly.string(from: date)
    }

    /// `2026-10-22T15:00:00-04:00` with the local offset (timed dates that should read as local time).
    public static func localRFC3339(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}

/// Date math for "move this to…" actions.
public enum Reschedule {
    /// `day`'s date with `time`'s hour and minute (when `time` is given).
    public static func day(_ day: Date, keepingTimeOf time: Date?, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: day)
        guard let time else { return start }
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: start) ?? start
    }

    /// The next Monday strictly after `date`'s day.
    public static func nextMonday(after date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.nextDate(after: start, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? start
    }
}
