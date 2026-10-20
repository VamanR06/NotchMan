import Foundation
import Testing
@testable import TasksApp

/// A database schema shaped like Notion's API response for a typical task board.
nonisolated(unsafe) private let boardJSON: [String: Any] = [
    "id": "db1",
    "title": [["plain_text": "Task Board"]],
    "url": "https://www.notion.so/db1",
    "properties": [
        "Name": ["type": "title"],
        "Created": ["type": "date"],
        "Due": ["type": "date"],
        "Archived": ["type": "checkbox"],
        "Status": [
            "type": "status",
            "status": [
                "options": [
                    ["id": "a", "name": "Not started"],
                    ["id": "b", "name": "In progress"],
                    ["id": "c", "name": "Done"],
                    ["id": "d", "name": "Won't do"],
                ],
                "groups": [
                    ["name": "To-do", "option_ids": ["a"]],
                    ["name": "In progress", "option_ids": ["b"]],
                    ["name": "Complete", "option_ids": ["c", "d"]],
                ],
            ],
        ],
    ],
]

@Suite struct SchemaDetectionTests {
    @Test func detectsStatusCompleteGroup() throws {
        let db = try #require(TaskDatabase(json: boardJSON))
        #expect(db.title == "Task Board")
        let rule = try #require(db.doneRules.first)
        #expect(rule.kind == .status && rule.property == "Status")
        #expect(rule.doneOptions == ["Done", "Won't do"])
        #expect(rule.notDoneValue == "Not started")
    }

    @Test func prefersDueDateProperty() throws {
        let db = try #require(TaskDatabase(json: boardJSON))
        #expect(db.dateProperties.first == "Due")
    }

    @Test func fallsBackToDoneCheckbox() throws {
        let json: [String: Any] = ["id": "db2", "properties": [
            "Archived": ["type": "checkbox"],
            "Done": ["type": "checkbox"],
            "Stage": ["type": "select", "select": ["options": [["name": "Todo"], ["name": "Blocked"]]]],
        ]]
        let db = try #require(TaskDatabase(json: json))
        #expect(db.doneRules.map(\.property) == ["Done", "Archived"])
        #expect(db.doneRules.first?.kind == .checkbox)
    }

    @Test func detectsSelectWithDoneOption() throws {
        let json: [String: Any] = ["id": "db3", "properties": [
            "Stage": ["type": "select", "select": ["options": [["name": "Todo"], ["name": "Completed"]]]],
        ]]
        let rule = try #require(TaskDatabase(json: json)?.doneRules.first)
        #expect(rule.kind == .select && rule.doneOptions == ["Completed"])
    }
}

@Suite struct DoneRuleTests {
    private let status = DoneRule(property: "Status", kind: .status, doneOptions: ["Done"], allOptions: ["Not started", "In progress", "Done"])

    @Test func checkingOffSetsDoneOption() {
        let value = status.value(done: true, original: "In progress")
        #expect((value?["status"] as? [String: String]) == ["name": "Done"])
    }

    @Test func uncheckingRestoresOriginalValue() {
        let value = status.value(done: false, original: "In progress")
        #expect((value?["status"] as? [String: String]) == ["name": "In progress"])
    }

    @Test func uncheckingFallsBackToFirstOpenOption() {
        let value = status.value(done: false, original: "Done")
        #expect((value?["status"] as? [String: String]) == ["name": "Not started"])
    }

    @Test func checkboxValue() {
        let rule = DoneRule(property: "Done", kind: .checkbox, doneOptions: [], allOptions: [])
        #expect(rule.value(done: true, original: nil)?["checkbox"] as? Bool == true)
        #expect(rule.isDone(["checkbox": true]))
    }
}

@MainActor @Suite struct PageParsingTests {
    @Test func parsesTaskPage() throws {
        let db = try #require(TaskDatabase(json: boardJSON))
        let page: [String: Any] = [
            "id": "p1",
            "url": "https://www.notion.so/p1",
            "properties": [
                "Name": ["type": "title", "title": [["plain_text": "Write "], ["plain_text": "report"]]],
                "Due": ["type": "date", "date": ["start": "2026-10-20"]],
                "Status": ["type": "status", "status": ["name": "In progress"]],
            ],
        ]
        let task = try #require(NotionClient.task(from: page, db: db, dueProperty: "Due", doneRule: db.doneRules.first))
        #expect(task.title == "Write report")
        #expect(task.dueIsAllDay && task.due != nil)
        #expect(!task.isDone)
        #expect(task.originalValue == "In progress")
    }

    @Test func notDoneFilterExcludesEveryDoneOption() throws {
        let rule = try #require(TaskDatabase(json: boardJSON)?.doneRules.first)
        let filter = try #require(NotionClient.notDoneFilter(rule))
        let clauses = try #require(filter["and"] as? [[String: Any]])
        #expect(clauses.count == 2)
    }
}
