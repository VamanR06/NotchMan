import Foundation
import Testing
@testable import TasksApp

@MainActor @Suite struct BatchRescheduleTests {
    private let calendar = Calendar.current
    /// Wednesday 2026-10-21, noon local time.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))! }

    private func at(_ day: Int, _ hour: Int? = nil) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour ?? 0))!
    }

    private func task(_ id: String, due: Date?, allDay: Bool = true) -> NotionTask {
        NotionTask(id: id, title: id, due: due, dueIsAllDay: allDay, isDone: false, originalValue: nil,
                   url: nil, databaseID: "db", databaseTitle: "Board")
    }

    private func app() -> TasksApp {
        let app = TasksApp()
        // Overdue: a (19th), b (20th 9:00); today: c; upcoming: d (25th); no date: e.
        app.useTasksForTesting([
            task("a", due: at(19)), task("b", due: at(20, 9), allDay: false), task("c", due: at(21)),
            task("d", due: at(25)), task("e", due: nil),
        ], now: now)
        return app
    }

    @Test func selectingASectionPicksAllOfIt() {
        let app = app()
        app.selectAll(in: .overdue)
        #expect(app.selectedIDs == ["a", "b"])
        app.selectAll()
        #expect(app.selectedIDs.count == 5)
        app.clearSelection()
        #expect(!app.isSelecting)
    }

    @Test func shiftClickSelectsARangeInListOrder() {
        let app = app()
        app.toggleSelection(app.displayedTasks[1])  // b
        app.selectRange(to: app.displayedTasks[3])  // d
        #expect(app.selectedIDs == ["b", "c", "d"])
        app.toggleSelection(app.displayedTasks[2])  // c off again
        #expect(app.selectedIDs == ["b", "d"])
    }

    @Test func quickMovesKeepEachTasksTimeAndDateOnlyStaysDateOnly() {
        let app = app()
        app.selectAll(in: .overdue)
        let changes = TasksApp.changes(app.selectedTasks, option: .today, now: now)
        let a = changes.first { $0.task.id == "a" }!
        let b = changes.first { $0.task.id == "b" }!
        #expect(a.allDay && calendar.isDate(a.due!, inSameDayAs: now))
        #expect(!b.allDay && calendar.component(.hour, from: b.due!) == 9 && calendar.isDate(b.due!, inSameDayAs: now))
    }

    @Test func pushAWeekMovesEachFromItsOwnDate() {
        let changes = TasksApp.changes([task("a", due: at(19)), task("d", due: at(25)), task("e", due: nil)], option: .pushWeek, now: now)
        #expect(changes.map { calendar.component(.day, from: $0.due!) } == [26, 1, 28])
    }

    @Test func pickedDateIsSharedButTimesSurviveUnlessSet() {
        let tasks = [task("a", due: at(19)), task("b", due: at(20, 9), allDay: false)]
        let date = at(30, 15)
        let kept = TasksApp.changes(tasks, to: date, includeTime: false)
        #expect(kept[0].allDay && calendar.component(.day, from: kept[0].due!) == 30)
        #expect(!kept[1].allDay && calendar.component(.hour, from: kept[1].due!) == 9 && calendar.component(.day, from: kept[1].due!) == 30)
        let set = TasksApp.changes(tasks, to: date, includeTime: true)
        #expect(set.allSatisfy { !$0.allDay && $0.due == date })
    }
}
