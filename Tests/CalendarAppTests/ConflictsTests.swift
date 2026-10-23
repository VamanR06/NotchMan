import Foundation
import Testing
@testable import CalendarApp

@Suite struct ConflictsTests {
    private let base = Date(timeIntervalSince1970: 1_792_497_600)

    private func event(_ id: String, _ title: String = "E", from start: Double, to end: Double, allDay: Bool = false,
                       declined: Bool = false, eventID: String? = nil) -> CalendarItem {
        var item = CalendarItem(id: id, title: title, start: base + start * 3600, end: base + end * 3600, isAllDay: allDay,
                                color: .blue, calendarName: "C", eventID: eventID ?? id, url: nil, meetingURL: nil, location: nil)
        item.declined = declined
        return item
    }

    @Test func overlappingEventsConflictBothWays() {
        let found = Conflicts.find([event("a", from: 10, to: 11), event("b", from: 10.5, to: 12), event("c", from: 12, to: 13)])
        #expect(found["a"]?.map(\.id) == ["b"])
        #expect(found["b"]?.map(\.id) == ["a"])
        // Back-to-back isn't a conflict.
        #expect(found["c"] == nil)
    }

    @Test func longEventOverlapsSeveral() {
        let found = Conflicts.find([event("all", from: 9, to: 17), event("x", from: 10, to: 11), event("y", from: 14, to: 15)])
        #expect(Set(found["all"]?.map(\.id) ?? []) == ["x", "y"])
    }

    @Test func declinedAllDayAndDuplicatesDontCount() {
        let found = Conflicts.find([
            event("a", "Sync", from: 10, to: 11),
            event("declined", from: 10, to: 11, declined: true),
            event("holiday", from: 0, to: 24, allDay: true),
            // The same meeting on a second calendar.
            event("a-copy", "Sync", from: 10, to: 11, eventID: "other"),
            event("shared", "Sync", from: 10, to: 11, eventID: "a"),
        ])
        #expect(found.isEmpty)
    }
}
