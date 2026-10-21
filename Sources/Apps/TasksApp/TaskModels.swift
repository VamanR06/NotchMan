import Foundation
import NotchKit

/// A task (page) from a Notion database.
struct NotionTask: Identifiable, Hashable {
    let id: String
    let title: String
    var due: Date?
    var dueIsAllDay: Bool
    var isDone: Bool
    /// The page's status/select value when loaded, so un-checking can restore it.
    let originalValue: String?
    let url: URL?
    let databaseID: String
    let databaseTitle: String
}

/// How a database marks a task as done.
struct DoneRule: Hashable {
    enum Kind: String, Hashable {
        case status, checkbox, select
    }

    let property: String
    let kind: Kind
    /// Option names meaning "done" (status/select). Empty for checkbox.
    let doneOptions: [String]
    /// Every option name, in schema order (status/select).
    let allOptions: [String]

    var label: String {
        switch kind {
        case .checkbox: "\(property) (checkbox)"
        case .status, .select: "\(property) → \(doneOptions.joined(separator: ", "))"
        }
    }

    /// The option to set when checking a task off.
    var doneValue: String? { doneOptions.first }

    /// The option to restore when un-checking, if the original value isn't usable.
    var notDoneValue: String? { allOptions.first { !doneOptions.contains($0) } }

    func isDone(_ property: [String: Any]?) -> Bool {
        guard let property else { return false }
        switch kind {
        case .checkbox:
            return property["checkbox"] as? Bool ?? false
        case .status, .select:
            return Self.optionName(property, kind: kind).map(doneOptions.contains) ?? false
        }
    }

    static func optionName(_ property: [String: Any]?, kind: Kind) -> String? {
        (property?[kind.rawValue] as? [String: Any])?["name"] as? String
    }

    /// Notion property value that marks the task done or not done.
    func value(done: Bool, original: String?) -> [String: Any]? {
        switch kind {
        case .checkbox:
            return ["checkbox": done]
        case .status, .select:
            let restore = original.flatMap { doneOptions.contains($0) ? nil : $0 } ?? notDoneValue
            guard let name = done ? doneValue : restore else { return nil }
            return [kind.rawValue: ["name": name]]
        }
    }
}

/// A Notion database the integration can see, with what we detected about its schema.
struct TaskDatabase: Identifiable, Hashable {
    let id: String
    let title: String
    let url: URL?
    let dateProperties: [String]
    /// Candidate ways to tell if a task is done, best first.
    let doneRules: [DoneRule]

    private static let doneWords = ["done", "complete", "completed", "finished", "closed", "shipped", "resolved"]

    /// Builds from a Notion database object (as returned by search / retrieve database).
    init?(json db: [String: Any]) {
        guard let id = db["id"] as? String else { return nil }
        self.id = id
        let titleParts = db["title"] as? [[String: Any]] ?? []
        let title = titleParts.compactMap { $0["plain_text"] as? String }.joined()
        self.title = title.isEmpty ? "Untitled" : title
        self.url = (db["url"] as? String).flatMap(URL.init(string:))

        let properties = db["properties"] as? [String: [String: Any]] ?? [:]
        dateProperties = properties.filter { $0.value["type"] as? String == "date" }.keys.sorted { lhs, rhs in
            // Prefer properties that look like a due date.
            let rank = { (name: String) in name.lowercased().contains("due") ? 0 : 1 }
            return (rank(lhs), lhs) < (rank(rhs), rhs)
        }

        var status: [DoneRule] = [], checkbox: [DoneRule] = [], select: [DoneRule] = []
        for (name, property) in properties {
            switch property["type"] as? String {
            case "status":
                let config = property["status"] as? [String: Any] ?? [:]
                let options = config["options"] as? [[String: Any]] ?? []
                let names = options.compactMap { $0["name"] as? String }
                // Notion's built-in "Complete" group holds the done options.
                let groups = config["groups"] as? [[String: Any]] ?? []
                let completeIDs = Set(groups
                    .filter { ($0["name"] as? String)?.lowercased() == "complete" }
                    .flatMap { $0["option_ids"] as? [String] ?? [] })
                var done = options.filter { ($0["id"] as? String).map(completeIDs.contains) ?? false }
                    .compactMap { $0["name"] as? String }
                if done.isEmpty { done = names.filter(Self.looksDone) }
                if !done.isEmpty {
                    status.append(DoneRule(property: name, kind: .status, doneOptions: done, allOptions: names))
                }
            case "checkbox":
                checkbox.append(DoneRule(property: name, kind: .checkbox, doneOptions: [], allOptions: []))
            case "select":
                let names = (property["select"] as? [String: Any])?["options"] as? [[String: Any]] ?? []
                let all = names.compactMap { $0["name"] as? String }
                let done = all.filter(Self.looksDone)
                if !done.isEmpty {
                    select.append(DoneRule(property: name, kind: .select, doneOptions: done, allOptions: all))
                }
            default:
                break
            }
        }
        // Checkboxes named like "Done" beat other checkboxes.
        checkbox.sort { (Self.looksDone($0.property) ? 0 : 1, $0.property) < (Self.looksDone($1.property) ? 0 : 1, $1.property) }
        doneRules = status.sorted { $0.property < $1.property } + checkbox + select.sorted { $0.property < $1.property }
    }

    private static func looksDone(_ name: String) -> Bool {
        doneWords.contains(name.lowercased().trimmingCharacters(in: .whitespaces))
    }
}

/// Quick "move to…" choices for a task's due date.
enum TaskDueOption: CaseIterable, Identifiable {
    case today, tomorrow, nextMonday, pushWeek

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .nextMonday: "Next Monday"
        case .pushWeek: "Push 1 Week"
        }
    }

    /// The new due date. A task with a time keeps its time of day; "Push 1 Week" moves from the current due
    /// date (or today if there is none).
    func target(for task: NotionTask, now: Date, calendar: Calendar = .current) -> Date {
        let time = task.dueIsAllDay ? nil : task.due
        switch self {
        case .today:
            return Reschedule.day(now, keepingTimeOf: time, calendar: calendar)
        case .tomorrow:
            return Reschedule.day(calendar.date(byAdding: .day, value: 1, to: now)!, keepingTimeOf: time, calendar: calendar)
        case .nextMonday:
            return Reschedule.day(Reschedule.nextMonday(after: now, calendar: calendar), keepingTimeOf: time, calendar: calendar)
        case .pushWeek:
            let base = task.due ?? calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: 7, to: base)!
        }
    }
}
