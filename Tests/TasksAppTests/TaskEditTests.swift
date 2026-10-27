import Foundation
import Testing
import NotchKit
@testable import TasksApp

@MainActor @Suite struct TaskEditTests {
    private let db = TaskDatabase(json: [
        "id": "db", "title": [["plain_text": "Groceries"]],
        "properties": ["Item": ["type": "title"], "Due": ["type": "date"]],
    ])!

    @Test func editWritesTheTitleToTheDatabasesTitleProperty() throws {
        let due = Date(timeIntervalSince1970: 1_792_497_600)
        let body = NotionClient.updateBody(in: db, title: "Oat milk", dueProperty: "Due", due: due, allDay: true)
        let properties = try #require(body["properties"] as? [String: Any])
        let title = try #require((properties["Item"] as? [String: Any])?["title"] as? [[String: Any]])
        #expect((title.first?["text"] as? [String: Any])?["content"] as? String == "Oat milk")
        let date = try #require((properties["Due"] as? [String: Any])?["date"] as? [String: Any])
        #expect(date["start"] as? String == DateParsing.dayString(due))
    }

    @Test func clearingTheDueDateSendsNull() throws {
        let body = NotionClient.updateBody(in: db, title: "Oat milk", dueProperty: "Due", due: nil, allDay: true)
        let properties = try #require(body["properties"] as? [String: Any])
        #expect((properties["Due"] as? [String: Any])?["date"] is NSNull)
        // A database without a due property only gets the title.
        let titleOnly = NotionClient.updateBody(in: db, title: "x", dueProperty: nil, due: nil, allDay: true)
        #expect((titleOnly["properties"] as? [String: Any])?.count == 1)
    }
}
