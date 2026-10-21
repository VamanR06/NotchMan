import Foundation
import Testing
import NotchKit
@testable import TasksApp

@Suite struct TaskRescheduleTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Detroit")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func task(due: Date?, allDay: Bool) -> NotionTask {
        NotionTask(id: "p", title: "T", due: due, dueIsAllDay: allDay, isDone: false, originalValue: nil,
                   url: nil, databaseID: "db", databaseTitle: "DB")
    }

    // Wednesday 2026-10-21, 4:30 PM.
    private var now: Date { date(2026, 10, 21, 16, 30) }

    @Test func dateOnlyTasksMoveToDays() {
        let t = task(due: date(2026, 10, 15), allDay: true)
        #expect(TaskDueOption.today.target(for: t, now: now, calendar: calendar) == date(2026, 10, 21))
        #expect(TaskDueOption.tomorrow.target(for: t, now: now, calendar: calendar) == date(2026, 10, 22))
        #expect(TaskDueOption.nextMonday.target(for: t, now: now, calendar: calendar) == date(2026, 10, 26))
        #expect(TaskDueOption.pushWeek.target(for: t, now: now, calendar: calendar) == date(2026, 10, 22),
                "a week from the current due date")
    }

    @Test func timedTasksKeepTheirTime() {
        let t = task(due: date(2026, 10, 15, 14, 0), allDay: false)
        #expect(TaskDueOption.tomorrow.target(for: t, now: now, calendar: calendar) == date(2026, 10, 22, 14, 0))
        #expect(TaskDueOption.pushWeek.target(for: t, now: now, calendar: calendar) == date(2026, 10, 22, 14, 0))
    }

    @Test func undatedTasksPushFromToday() {
        #expect(TaskDueOption.pushWeek.target(for: task(due: nil, allDay: true), now: now, calendar: calendar)
                == date(2026, 10, 28))
    }

    @Test func nextMondayIsStrictlyAfter() {
        // Monday 2026-10-26 → the following Monday.
        #expect(Reschedule.nextMonday(after: date(2026, 10, 26, 9), calendar: calendar) == date(2026, 11, 2))
    }

    @MainActor @Test func notionDateValues() {
        let allDay = NotionClient.dateValue(date(2026, 10, 22), allDay: true)
        #expect((allDay["date"] as? [String: String])?["start"]?.count == 10)
        let timed = NotionClient.dateValue(Date(timeIntervalSince1970: 1_792_670_400), allDay: false)
        let start = (timed["date"] as? [String: String])?["start"] ?? ""
        #expect(DateParsing.parse(start)?.0 == Date(timeIntervalSince1970: 1_792_670_400), "round-trips: \(start)")
        #expect(NotionClient.dateValue(nil, allDay: true)["date"] is NSNull)
    }

    @Test func localTimestampsCarryTheOffset() {
        let detroit = TimeZone(identifier: "America/Detroit")!
        let s = DateParsing.localRFC3339(Date(timeIntervalSince1970: 1_792_670_400), timeZone: detroit)
        #expect(s.hasSuffix("-04:00"), "\(s)")
    }
}
