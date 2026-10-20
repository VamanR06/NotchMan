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
}
