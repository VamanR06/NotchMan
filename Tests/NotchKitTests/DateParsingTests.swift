import Foundation
import Testing
import NotchKit

@Suite struct DateParsingTests {
    @Test func parsesAllDayDates() throws {
        let (date, allDay) = try #require(DateParsing.parse("2026-10-20"))
        #expect(allDay)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date)
        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 20 && parts.hour == 0)
    }

    @Test func parsesGoogleDateTimes() throws {
        let (date, allDay) = try #require(DateParsing.parse("2026-10-20T10:00:00-04:00"))
        #expect(!allDay)
        #expect(date == Date(timeIntervalSince1970: 1_792_504_800))
    }

    @Test func parsesNotionFractionalDateTimes() throws {
        let (date, allDay) = try #require(DateParsing.parse("2026-10-20T14:00:00.000+00:00"))
        #expect(!allDay)
        #expect(date == Date(timeIntervalSince1970: 1_792_504_800))
    }

    @Test func rejectsGarbage() {
        #expect(DateParsing.parse("not a date") == nil)
    }
}
