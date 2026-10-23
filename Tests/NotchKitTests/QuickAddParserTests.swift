import Foundation
import Testing
@testable import NotchKit

@Suite struct QuickAddParserTests {
    private let calendar = Calendar.current
    private let now = Date()

    @Test func weekdayAndTimeMakeAnEvent() throws {
        let parsed = QuickAddParser.parse("Call recruiter fri 3pm", now: now)
        #expect(parsed.title == "Call recruiter")
        #expect(parsed.hasTime && parsed.looksLikeEvent)
        let date = try #require(parsed.date)
        #expect(calendar.component(.weekday, from: date) == 6)
        #expect(calendar.component(.hour, from: date) == 15)
        #expect(date > now.addingTimeInterval(-60))
    }

    @Test func shorthandDayWithoutTimeIsATask() throws {
        let parsed = QuickAddParser.parse("buy milk tmrw", now: now)
        #expect(parsed.title == "buy milk")
        #expect(!parsed.hasTime && !parsed.looksLikeEvent)
        let date = try #require(parsed.date)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
        #expect(date == tomorrow)
    }

    @Test func durationIsTakenOutOfTheTitle() {
        let parsed = QuickAddParser.parse("Design review tomorrow at 10am for 45m", now: now)
        #expect(parsed.title == "Design review")
        #expect(parsed.duration == TimeInterval(2700))
        #expect(parsed.hasTime)
        let hours = QuickAddParser.parse("Deep work for 1.5 hours", now: now)
        #expect(hours.duration == 5400)
        #expect(hours.title == "Deep work")
    }

    @Test func connectiveBeforeTheDateIsDropped() {
        #expect(QuickAddParser.parse("Submit OA by friday", now: now).title == "Submit OA")
        #expect(QuickAddParser.parse("Dentist on monday at noon", now: now).title == "Dentist")
    }

    @Test func noDateLeavesTextAlone() {
        let parsed = QuickAddParser.parse("  Read the paper  ", now: now)
        #expect(parsed == QuickAdd(title: "Read the paper", date: nil, hasTime: false, duration: nil))
    }

    @Test func relativeHoursNormalize() throws {
        let parsed = QuickAddParser.parse("stretch in 2h", now: now)
        #expect(parsed.title == "stretch")
        #expect(parsed.hasTime)
        let date = try #require(parsed.date)
        #expect(abs(date.timeIntervalSince(now) - 7200) < 120)
    }
}
