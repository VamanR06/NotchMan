import Foundation

/// Double-bookings: timed events you haven't declined whose times overlap. The same meeting showing on two of
/// your calendars (same title and times, or the same Google event) isn't a conflict.
enum Conflicts {
    /// For each event that overlaps another, the events it overlaps.
    static func find(_ items: [CalendarItem]) -> [String: [CalendarItem]] {
        let timed = items.filter { !$0.isAllDay && !$0.declined && $0.end != nil }.sorted { $0.start < $1.start }
        var result: [String: [CalendarItem]] = [:]
        for (index, item) in timed.enumerated() {
            guard let end = item.end else { continue }
            for other in timed[(index + 1)...] {
                guard other.start < end else { break }
                guard let otherEnd = other.end, item.start < otherEnd, !isSameMeeting(item, other) else { continue }
                result[item.id, default: []].append(other)
                result[other.id, default: []].append(item)
            }
        }
        return result
    }

    static func isSameMeeting(_ a: CalendarItem, _ b: CalendarItem) -> Bool {
        if let x = a.eventID, x == b.eventID { return true }
        return a.title == b.title && a.start == b.start && a.end == b.end
    }
}
