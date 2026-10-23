import Foundation
import Testing
import NotchKit
@testable import TodayApp

@MainActor @Suite(.serialized) struct TodayAppTests {
    @Test func sectionsPutNeedsYouFirstAndSortByTime() {
        let board = NotchBoard.shared
        let now = Date()
        board.publish([
            BoardItem(id: "late", kind: .event, title: "Late", date: now + 7200),
            BoardItem(id: "soon", kind: .event, title: "Soon", date: now + 600),
        ], from: "test.calendar")
        board.publish([BoardItem(id: "agent", kind: .agent, title: "Refactor")], from: "test.chat")
        defer {
            board.publish([], from: "test.calendar")
            board.publish([], from: "test.chat")
        }
        let app = TodayApp()
        #expect(app.sections.map(\.id) == ["needs", "events"])
        #expect(app.displayedItems.map(\.id) == ["agent", "soon", "late"])
        #expect(app.dockBadge == .dot(.orange))
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
}
