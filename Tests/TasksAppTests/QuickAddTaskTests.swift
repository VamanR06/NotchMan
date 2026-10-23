import Foundation
import Testing
import NotchKit
@testable import TasksApp

private func db(_ id: String, _ title: String, titleProperty: String = "Name") -> TaskDatabase {
    TaskDatabase(json: [
        "id": id,
        "title": [["plain_text": title]],
        "properties": [titleProperty: ["type": "title"], "Due": ["type": "date"]],
    ])!
}

@MainActor @Suite struct QuickAddTaskTests {
    private let dbs = [db("a", "Task Board"), db("b", "School Work"), db("c", "Groceries", titleProperty: "Item")]

    @Test func detectsTitleProperty() {
        #expect(dbs[2].titleProperty == "Item")
    }

    @Test func hashtagPicksTheDatabaseByWholeWord() throws {
        let (target, title) = try #require(TasksApp.route("essay draft #school", databases: dbs, defaultID: "a"))
        #expect(target.id == "b")
        #expect(title == "essay draft")
    }

    @Test func unknownTagStaysInTheTitleAndUsesTheDefault() throws {
        let (target, title) = try #require(TasksApp.route("fix #42 bug", databases: dbs, defaultID: "c"))
        #expect(target.id == "c")
        #expect(title == "fix #42 bug")
        // A missing default falls back to the first list; no lists means nowhere to add.
        #expect(TasksApp.route("x", databases: dbs, defaultID: "gone")?.0.id == "a")
        #expect(TasksApp.route("x", databases: [], defaultID: "a") == nil)
    }

    @Test func createBodySetsTitleAndDue() throws {
        let due = Date(timeIntervalSince1970: 1_792_497_600)
        let body = NotionClient.createBody(in: dbs[2], title: "Milk", dueProperty: "Due", due: due, allDay: true)
        let parent = try #require(body["parent"] as? [String: Any])
        #expect(parent["database_id"] as? String == "c")
        let properties = try #require(body["properties"] as? [String: Any])
        #expect(properties["Item"] != nil)
        let date = try #require((properties["Due"] as? [String: Any])?["date"] as? [String: Any])
        #expect(date["start"] as? String == DateParsing.dayString(due))
        // No date: no due property written.
        let undated = NotionClient.createBody(in: dbs[0], title: "x", dueProperty: "Due", due: nil, allDay: false)
        #expect((undated["properties"] as? [String: Any])?["Due"] == nil)
    }

    @Test func quickAddMessageRoundTrips() {
        let item = QuickAdd(title: "Call recruiter", date: Date(timeIntervalSince1970: 1_792_500_000), hasTime: true, duration: 1800)
        let message = NotchMessage.quickAdd(item, asEvent: true)
        #expect(message.name == NotchMessage.quickAddEventName)
        #expect(message.quickAdd == item)
        #expect(NotchMessage.quickAdd(item, asEvent: false).name == NotchMessage.quickAddTaskName)
    }
}
