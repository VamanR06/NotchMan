import Foundation
import Testing
@testable import CalendarApp

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

@Suite struct LoopbackServerTests {
    @Test func receivesOAuthCallback() async throws {
        let server = try LoopbackServer()
        let port = try await server.start()

        // A stray request (like a favicon fetch) must not complete the flow.
        let favicon = URL(string: "http://127.0.0.1:\(port)/favicon.ico")!
        let (_, faviconResponse) = try await URLSession.shared.data(from: favicon)
        #expect((faviconResponse as? HTTPURLResponse)?.statusCode == 404)

        async let callback = server.waitForCallback()
        let redirect = URL(string: "http://127.0.0.1:\(port)/?code=abc123&state=xyz")!
        let (body, response) = try await URLSession.shared.data(from: redirect)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("connected"))

        let url = try await callback
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "code" }?.value == "abc123")
        #expect(items.first { $0.name == "state" }?.value == "xyz")
    }

    @Test func cancelFailsWaiter() async throws {
        let server = try LoopbackServer()
        _ = try await server.start()
        server.cancel()
        await #expect(throws: LoopbackServer.ServerError.self) { try await server.waitForCallback() }
    }
}
