import Foundation
import Testing
@testable import ChatApp

@Suite struct ClaudeUsageTests {
    private func line(id: String, request: String, time: String, model: String = "claude-opus-5-5",
                      cwd: String = "/Users/me/GitHub/NotchMan", session: String = "s1",
                      input: Int = 10, output: Int = 100, write: Int = 1000, read: Int = 50_000) -> String {
        #"{"type":"assistant","timestamp":"\#(time)","requestId":"\#(request)","sessionId":"\#(session)","cwd":"\#(cwd)","message":{"id":"\#(id)","model":"\#(model)","role":"assistant","content":[{"type":"text","text":"secret words"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(write),"cache_read_input_tokens":\#(read)}}}"#
    }

    @Test func parsesUsageAndSkipsDuplicatesAndOtherLines() {
        let text = [
            line(id: "m1", request: "r1", time: "2026-10-23T10:00:00.000Z"),
            line(id: "m1", request: "r1", time: "2026-10-23T10:00:01.000Z"),       // streamed duplicate
            #"{"type":"user","timestamp":"2026-10-23T09:59:00.000Z","message":{"role":"user","content":"hi"}}"#,
            "not json at all \"usage\"",
            line(id: "m2", request: "r2", time: "2026-10-23T11:00:00Z", model: "claude-haiku-4-5-20251001"),
        ].joined(separator: "\n")
        var seen = Set<String>()
        let records = UsageScanner.records(fromLines: Data(text.utf8), seen: &seen)
        #expect(records.count == 2)
        #expect(records[0].project == "NotchMan" && records[0].work == 1110 && records[0].cacheRead == 50_000)
        #expect(records[1].model == "claude-haiku-4-5-20251001")
    }

    @Test func summarizesWindowsAndBreakdowns() {
        let now = Date(timeIntervalSince1970: 1_792_800_000)
        func r(hoursAgo: Double, model: String, project: String, session: String, work: Int) -> UsageRecord {
            UsageRecord(timestamp: now.addingTimeInterval(-hoursAgo * 3600), model: model, project: project,
                        sessionID: session, input: 0, output: work, cacheWrite: 0, cacheRead: 999)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let records = [
            r(hoursAgo: 1, model: "claude-opus-5-5", project: "NotchMan", session: "a", work: 300),
            r(hoursAgo: 4, model: "claude-opus-5-5", project: "NotchMan", session: "a", work: 200),
            r(hoursAgo: 30, model: "claude-haiku-4-5-20251001", project: "JobManager", session: "b", work: 100),
            r(hoursAgo: 24 * 9, model: "claude-opus-5-5", project: "Old", session: "c", work: 5000),  // outside 7 days
        ]
        let summary = UsageSummary(records: records, now: now, calendar: calendar) { $0 == "a" ? "notchman-engine-setup" : nil }
        #expect(summary.lastFiveHours.work == 500)
        #expect(summary.week.work == 600 && summary.week.cacheRead == 2997)
        #expect(summary.byModel.map(\.label) == ["Opus 5.5", "Haiku 4.5"])
        #expect(summary.byProject.map(\.work) == [500, 100])
        #expect(summary.bySession.map(\.label) == ["notchman-engine-setup", "JobManager"])
    }

    @Test func formatsModelsAndNumbers() {
        #expect(UsageSummary.modelLabel("claude-opus-4-8") == "Opus 4.8")
        #expect(UsageSummary.modelLabel("claude-sonnet-5") == "Sonnet 5")
        #expect(UsageSummary.format(950) == "950")
        #expect(UsageSummary.format(12_345) == "12.3K")
        #expect(UsageSummary.format(3_400_000) == "3.4M")
        #expect(UsageSummary.format(2_100_000_000) == "2.1B")
    }
}
