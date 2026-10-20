import AppKit
import SwiftUI

/// A single entry on the unified timeline, from any source.
struct CalendarItem: Identifiable, Hashable {
    enum Source: Hashable {
        case google(calendarName: String)
        case notion(databaseName: String)

        var label: String {
            switch self {
            case .google(let name), .notion(let name): name
            }
        }
    }

    let id: String
    let title: String
    let start: Date
    let end: Date?
    let isAllDay: Bool
    let color: Color
    let source: Source
    /// Event page (Google Calendar web) or Notion page.
    let url: URL?
    let meetingURL: URL?
    let location: String?

    func isOngoing(at now: Date) -> Bool {
        guard !isAllDay, let end else { return false }
        return start <= now && now < end
    }
}

enum DateParsing {
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
    static func parse(_ string: String) -> (Date, isAllDay: Bool)? {
        if string.count == 10, let d = dayOnly.date(from: string) { return (d, true) }
        if let d = internet.date(from: string) ?? fractional.date(from: string) { return (d, false) }
        return nil
    }

    static func rfc3339(_ date: Date) -> String {
        internet.string(from: date)
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

/// Opening links in Notion / Notion Calendar, preferring the desktop apps when installed.
@MainActor
enum NotionLinks {
    static let notionCalendarBundleID = "com.cron.electron"
    static let notionBundleID = "notion.id"

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

    /// Opens a Notion page in the desktop app if installed, otherwise in the browser.
    static func openNotionPage(_ url: URL) {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: notionBundleID) != nil,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "notion"
            if let appURL = components.url, NSWorkspace.shared.open(appURL) { return }
        }
        NSWorkspace.shared.open(url)
    }
}
