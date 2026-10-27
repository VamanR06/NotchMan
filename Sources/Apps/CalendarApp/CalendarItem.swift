import AppKit
import SwiftUI

/// A single event on the timeline.
struct CalendarItem: Identifiable, Hashable {
    let id: String
    var title: String
    var start: Date
    var end: Date?
    var isAllDay: Bool
    let color: Color
    let calendarName: String
    /// Google ids, for changing the event.
    var calendarID: String? = nil
    var eventID: String? = nil
    /// The calendar lets you change events (owner / writer).
    var canEdit = false
    /// Event page on Google Calendar web.
    let url: URL?
    let meetingURL: URL?
    var location: String?
    /// The event's description.
    var notes: String? = nil
    /// You declined this invitation.
    var declined = false

    /// Finished: timed events whose end (or start, with no end) has passed. All-day events never count.
    func isPast(at now: Date) -> Bool {
        guard !isAllDay else { return false }
        return (end ?? start) < now
    }

    func isOngoing(at now: Date) -> Bool {
        guard !isAllDay, let end else { return false }
        return start <= now && now < end
    }
}

/// Quick moves for an event; the event keeps its length.
enum EventMoveOption: CaseIterable, Identifiable {
    case later15, laterHour, tomorrow, nextWeek

    var id: Self { self }

    var title: String {
        switch self {
        case .later15: "15 Minutes Later"
        case .laterHour: "1 Hour Later"
        case .tomorrow: "Tomorrow, Same Time"
        case .nextWeek: "Next Week, Same Time"
        }
    }

    /// All-day events only move by whole days.
    static func options(for item: CalendarItem) -> [EventMoveOption] {
        item.isAllDay ? [.tomorrow, .nextWeek] : allCases
    }

    func newStart(for item: CalendarItem, calendar: Calendar = .current) -> Date {
        switch self {
        case .later15: item.start.addingTimeInterval(15 * 60)
        case .laterHour: item.start.addingTimeInterval(3600)
        case .tomorrow: calendar.date(byAdding: .day, value: 1, to: item.start)!
        case .nextWeek: calendar.date(byAdding: .day, value: 7, to: item.start)!
        }
    }
}

extension CalendarItem {
    /// How long the event lasts (Google's all-day end is exclusive, so a one-day event lasts one day).
    var duration: TimeInterval {
        if let end { return end.timeIntervalSince(start) }
        return isAllDay ? 86400 : 3600
    }

    /// Start and end after moving to `newStart`, keeping the length. All-day events snap to the day.
    func moved(to newStart: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        if isAllDay {
            let start = calendar.startOfDay(for: newStart)
            let days = max(Int((duration / 86400).rounded()), 1)
            return (start, calendar.date(byAdding: .day, value: days, to: start)!)
        }
        return (newStart, newStart.addingTimeInterval(duration))
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

/// Opening Notion Calendar, preferring the desktop app when installed.
@MainActor
enum NotionLinks {
    static let notionCalendarBundleID = "com.cron.electron"

    static var hasNotionCalendar: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: notionCalendarBundleID) != nil
    }

    /// Opens Notion Calendar (desktop app if installed, otherwise the web app).
    static func openNotionCalendar() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: notionCalendarBundleID) {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        } else if let web = URL(string: "https://calendar.notion.so") {
            NSWorkspace.shared.open(web)
        }
    }
}
