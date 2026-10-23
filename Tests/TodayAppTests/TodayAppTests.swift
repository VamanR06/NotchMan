import Foundation
import Testing
import NotchKit
@testable import TodayApp

@MainActor @Suite(.serialized) struct TodayAppTests {
    private let board = NotchBoard.shared

    /// Other suites in the same run (the Agents app's) publish to the shared board too.
    private func clear() {
        for app in ["test.calendar", "test.chat", "test.tasks", "chat", "calendar", "tasks", "jobs"] {
            board.publish([], from: app)
        }
    }

    @Test func happeningOnTheLeftDueOnTheRight() {
        clear()
        defer { clear() }
        let now = Date()
        board.publish([
            BoardItem(id: "late", kind: .event, title: "Late", date: now + 7200),
            BoardItem(id: "soon", kind: .event, title: "Soon", date: now + 600),
        ], from: "test.calendar")
        board.publish([
            BoardItem(id: "agent", kind: .agent, title: "Refactor"),
            BoardItem(id: "done", kind: .session, title: "Docs", date: now - 300),
            BoardItem(id: "busy", kind: .session, title: "Tests", date: now - 60, isWorking: true),
        ], from: "test.chat")
        board.publish([BoardItem(id: "task", kind: .task, title: "Essay")], from: "test.tasks")

        let app = TodayApp()
        let columns = app.columns
        #expect(columns.left.map(\.id) == ["events", "needs", "sessions"])
        #expect(columns.right.map(\.id) == ["tasks"])
        // Meetings by time; working sessions before finished ones; then the right column.
        #expect(app.displayedItems.map(\.id) == ["soon", "late", "agent", "busy", "done", "task"])
        #expect(app.dockBadge == .dot(.orange))
    }

    @Test func longListsFoldBehindMore() throws {
        clear()
        defer { clear() }
        board.publish((0..<9).map { BoardItem(id: "t\($0)", kind: .task, title: "Task \($0)") }, from: "test.tasks")
        let app = TodayApp()
        let tasks = try #require(app.columns.right.first)
        #expect(app.visibleItems(tasks).count == tasks.limit)
        app.toggleExpanded(tasks)
        #expect(app.visibleItems(tasks).count == 9)
    }

    @Test func quickAddFollowsTheTextUnlessSwitched() {
        let app = TodayApp()
        app.quickText = "Call recruiter fri 3pm"
        #expect(app.addsEvent && app.canAdd)
        app.forceEvent = false
        #expect(!app.addsEvent && app.canAdd)

        app.forceEvent = nil
        app.quickText = "buy milk"
        #expect(!app.addsEvent && app.canAdd)
        // An event needs a date.
        app.forceEvent = true
        #expect(!app.canAdd)
    }

    @Test func meetingAndRowTimes() {
        let now = Date(timeIntervalSince1970: 1_792_497_600)
        let meeting = BoardItem(id: "m", kind: .event, title: "Sync", date: now + 25 * 60)
        #expect(TodayFormat.meetingWhen(meeting, now: now).hasPrefix("in 25m · "))
        let later = BoardItem(id: "m", kind: .event, title: "Sync", date: now + 90 * 60)
        #expect(TodayFormat.meetingWhen(later, now: now).hasPrefix("in 1h 30m · "))
        let finished = BoardItem(id: "s", kind: .session, title: "Docs", date: now - 600)
        #expect(TodayFormat.when(finished, now: now) == "10m ago")
        let working = BoardItem(id: "s", kind: .session, title: "Docs", date: now - 7200, isWorking: true)
        #expect(TodayFormat.when(working, now: now) == "2h")
    }
}
