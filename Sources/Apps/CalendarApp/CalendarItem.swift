import AppKit
import SwiftUI

/// A single event on the timeline.
struct CalendarItem: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date?
    let isAllDay: Bool
    let color: Color
    let calendarName: String
    /// Event page on Google Calendar web.
    let url: URL?
    let meetingURL: URL?
    let location: String?

    func isOngoing(at now: Date) -> Bool {
        guard !isAllDay, let end else { return false }
        return start <= now && now < end
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
