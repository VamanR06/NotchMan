import Foundation
import SwiftUI
import Testing
import NotchKit
@testable import CalendarApp

@Suite struct EventRescheduleTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Detroit")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func event(_ start: Date, _ end: Date?, allDay: Bool = false) -> CalendarItem {
        CalendarItem(id: "g:1", title: "Standup", start: start, end: end, isAllDay: allDay, color: .blue,
                     calendarName: "Work", calendarID: "primary", eventID: "e1", canEdit: true,
                     url: nil, meetingURL: nil, location: nil)
    }

    @Test func quickMovesKeepTheLength() {
        let standup = event(date(2026, 10, 21, 10), date(2026, 10, 21, 10, 30))
        let later = standup.moved(to: EventMoveOption.later15.newStart(for: standup, calendar: calendar), calendar: calendar)
        #expect(later.start == date(2026, 10, 21, 10, 15) && later.end == date(2026, 10, 21, 10, 45))
        let tomorrow = standup.moved(to: EventMoveOption.tomorrow.newStart(for: standup, calendar: calendar), calendar: calendar)
        #expect(tomorrow.start == date(2026, 10, 22, 10) && tomorrow.end == date(2026, 10, 22, 10, 30))
        #expect(EventMoveOption.nextWeek.newStart(for: standup, calendar: calendar) == date(2026, 10, 28, 10))
    }

    @Test func allDayEventsMoveByWholeDays() {
        let trip = event(date(2026, 10, 21), date(2026, 10, 24), allDay: true)  // 3 days (end exclusive)
        #expect(EventMoveOption.options(for: trip) == [.tomorrow, .nextWeek])
        let moved = trip.moved(to: date(2026, 10, 30, 15), calendar: calendar)  // time is ignored
        #expect(moved.start == date(2026, 10, 30) && moved.end == date(2026, 11, 2))
    }

    @Test func eventWithoutEndDefaultsToAnHour() {
        let e = event(date(2026, 10, 21, 9), nil)
        #expect(e.moved(to: date(2026, 10, 21, 11), calendar: calendar).end == date(2026, 10, 21, 12))
    }

    @MainActor @Test func googleRequestBodies() {
        let timed = GoogleCalendarSource.moveBody(start: Date(timeIntervalSince1970: 1_792_670_400),
                                                  end: Date(timeIntervalSince1970: 1_792_672_200), allDay: false)
        let start = (timed["start"] as? [String: String])?["dateTime"] ?? ""
        #expect(DateParsing.parse(start)?.0 == Date(timeIntervalSince1970: 1_792_670_400))
        #expect((timed["start"] as? [String: String])?["timeZone"] == TimeZone.current.identifier)

        let allDay = GoogleCalendarSource.moveBody(start: Date(), end: Date().addingTimeInterval(86400), allDay: true)
        #expect((allDay["start"] as? [String: String])?["date"]?.count == 10)
        #expect((allDay["start"] as? [String: String])?["dateTime"] == nil)
    }

    @Test func onlyOwnersAndWritersCanMoveEvents() {
        func info(_ role: String) -> GoogleCalendarSource.CalendarInfo {
            .init(id: "c", name: "C", color: .blue, isPrimary: false, accessRole: role)
        }
        #expect(info("owner").canEdit && info("writer").canEdit)
        #expect(!info("reader").canEdit && !info("freeBusyReader").canEdit)
    }
}

@Suite struct PastEventTests {
    private func event(start: Date, end: Date?, allDay: Bool = false) -> CalendarItem {
        CalendarItem(id: "x", title: "E", start: start, end: end, isAllDay: allDay, color: .blue,
                     calendarName: "C", url: nil, meetingURL: nil, location: nil)
    }

    @Test func onlyFinishedTimedEventsArePast() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(event(start: now - 7200, end: now - 3600).isPast(at: now))
        #expect(!event(start: now - 1800, end: now + 1800).isPast(at: now), "in progress stays visible")
        #expect(!event(start: now + 600, end: now + 4200).isPast(at: now))
        #expect(event(start: now - 600, end: nil).isPast(at: now), "no end: started already")
        #expect(!event(start: now - 86400, end: now + 3600, allDay: true).isPast(at: now), "all-day never folds")
    }
}

@Suite struct CalendarDaysTests {
    private let cal = Calendar.current
    private var now: Date { cal.date(bySettingHour: 13, minute: 0, second: 0, of: Date())! }

    private func event(dayOffset: Int) -> CalendarItem {
        let start = cal.date(byAdding: .day, value: dayOffset, to: now)!
        return CalendarItem(id: "\(dayOffset)", title: "E", start: start, end: start.addingTimeInterval(1800), isAllDay: false,
                            color: .blue, calendarName: "C", url: nil, meetingURL: nil, location: nil)
    }

    @Test func todayAlwaysHasASection() {
        let days = CalendarDays.group([event(dayOffset: 2)], now: now)
        #expect(days.count == 2)
        #expect(cal.isDate(days[0].day, inSameDayAs: now) && days[0].items.isEmpty)
    }

    @Test func labelsTodayTomorrowAndLater() {
        #expect(CalendarDays.kind(of: now, now: now) == .today)
        #expect(CalendarDays.kind(of: cal.date(byAdding: .day, value: 1, to: now)!, now: now) == .tomorrow)
        #expect(CalendarDays.kind(of: cal.date(byAdding: .day, value: 3, to: now)!, now: now) == .later)
    }

    @Test func daysAreInOrder() {
        let days = CalendarDays.group([event(dayOffset: 3), event(dayOffset: 1), event(dayOffset: 0)], now: now)
        #expect(days.map(\.items.count) == [1, 1, 1])
        #expect(days.map(\.day) == days.map(\.day).sorted())
    }
}
