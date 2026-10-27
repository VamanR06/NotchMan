import Foundation
import Testing
@testable import CalendarApp

@MainActor @Suite struct EventEditTests {
    private let calendar = Calendar.current

    @Test func timedEditSendsTitlePlaceNotesAndTimes() throws {
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 14))!
        let edit = GoogleCalendarSource.EventEdit(title: "Design review", start: start, end: start.addingTimeInterval(1800),
                                                  allDay: false, location: "Room 4", notes: "Bring mocks")
        let body = GoogleCalendarSource.editBody(edit)
        #expect(body["summary"] as? String == "Design review")
        #expect(body["location"] as? String == "Room 4")
        #expect(body["description"] as? String == "Bring mocks")
        let startJSON = try #require(body["start"] as? [String: Any])
        #expect(startJSON["dateTime"] != nil && startJSON["timeZone"] as? String == TimeZone.current.identifier)
    }

    @Test func allDayEditSendsDatesWithAnExclusiveEnd() throws {
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28))!
        let edit = GoogleCalendarSource.EventEdit(title: "Offsite", start: day, end: calendar.date(byAdding: .day, value: 2, to: day)!,
                                                  allDay: true, location: "", notes: "")
        let body = GoogleCalendarSource.editBody(edit)
        #expect((body["start"] as? [String: Any])?["date"] as? String == "2026-10-28")
        // Two days (28th and 29th) end on the 30th, as Google stores it.
        #expect((body["end"] as? [String: Any])?["date"] as? String == "2026-10-30")
        // Cleared fields are sent empty so Google clears them too.
        #expect(body["location"] as? String == "")
    }
}
