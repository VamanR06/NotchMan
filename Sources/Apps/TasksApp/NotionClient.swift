import Foundation
import NotchKit

/// Minimal Notion API client using an internal integration token.
@MainActor
final class NotionClient {
    enum NotionError: LocalizedError {
        case noToken
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .noToken:
                "Not connected to Notion."
            case .http(403, _):
                "Notion refused the change. Make sure the integration has \"Update content\" capability."
            case .http(404, _):
                "Notion database not found. Is it still shared with the integration?"
            case .http(let code, let body):
                "Notion API error \(code): \(body.prefix(200))"
            }
        }
    }

    private static let apiVersion = "2022-06-28"
    private let keychain: Keychain

    init(keychain: Keychain) {
        self.keychain = keychain
    }

    var hasToken: Bool { keychain.string(for: "notion.token") != nil }

    func setToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        keychain.set(trimmed?.isEmpty == false ? trimmed : nil, for: "notion.token")
    }

    @discardableResult
    private func request(_ method: String, _ path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let token = keychain.string(for: "notion.token") else { throw NotionError.noToken }
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1" + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw NotionError.http(status, String(data: data, encoding: .utf8) ?? "") }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Databases shared with the integration.
    func databases() async throws -> [TaskDatabase] {
        var found: [TaskDatabase] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["filter": ["property": "object", "value": "database"], "page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            let response = try await request("POST", "/search", body: body)
            found += (response["results"] as? [[String: Any]] ?? []).compactMap(TaskDatabase.init(json:))
            cursor = response["has_more"] as? Bool == true ? response["next_cursor"] as? String : nil
        } while cursor != nil
        return found.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Open (not done) tasks in a database. Capped at 500 to keep the notch responsive.
    func openTasks(in db: TaskDatabase, dueProperty: String?, doneRule: DoneRule?) async throws -> [NotionTask] {
        var body: [String: Any] = ["page_size": 100]
        if let filter = Self.notDoneFilter(doneRule) { body["filter"] = filter }
        if let dueProperty { body["sorts"] = [["property": dueProperty, "direction": "ascending"]] }

        var tasks: [NotionTask] = []
        var cursor: String?
        repeat {
            if let cursor { body["start_cursor"] = cursor }
            let response = try await request("POST", "/databases/\(db.id)/query", body: body)
            for page in response["results"] as? [[String: Any]] ?? [] {
                if let task = Self.task(from: page, db: db, dueProperty: dueProperty, doneRule: doneRule), !task.isDone {
                    tasks.append(task)
                }
            }
            cursor = response["has_more"] as? Bool == true ? response["next_cursor"] as? String : nil
        } while cursor != nil && tasks.count < 500
        return tasks
    }

    /// Creates a task page in `db` and returns it.
    func createTask(in db: TaskDatabase, title: String, dueProperty: String?, due: Date?, allDay: Bool) async throws -> NotionTask? {
        let body = Self.createBody(in: db, title: title, dueProperty: dueProperty, due: due, allDay: allDay)
        let page = try await request("POST", "/pages", body: body)
        return Self.task(from: page, db: db, dueProperty: dueProperty, doneRule: nil)
    }

    static func createBody(in db: TaskDatabase, title: String, dueProperty: String?, due: Date?, allDay: Bool) -> [String: Any] {
        var properties: [String: Any] = [db.titleProperty: ["title": [["text": ["content": title]]]]]
        if let dueProperty, let due { properties[dueProperty] = dateValue(due, allDay: allDay) }
        return ["parent": ["database_id": db.id], "properties": properties]
    }

    func setDone(_ task: NotionTask, done: Bool, rule: DoneRule) async throws {
        guard let value = rule.value(done: done, original: task.originalValue) else { return }
        try await request("PATCH", "/pages/\(task.id)", body: ["properties": [rule.property: value]])
    }

    /// Saves an edited task: its title and (when the database has one) its due date, in one request.
    func update(_ task: NotionTask, in db: TaskDatabase, title: String, dueProperty: String?, due: Date?, allDay: Bool) async throws {
        try await request("PATCH", "/pages/\(task.id)", body: Self.updateBody(in: db, title: title, dueProperty: dueProperty, due: due, allDay: allDay))
    }

    static func updateBody(in db: TaskDatabase, title: String, dueProperty: String?, due: Date?, allDay: Bool) -> [String: Any] {
        var properties: [String: Any] = [db.titleProperty: ["title": [["text": ["content": title]]]]]
        if let dueProperty { properties[dueProperty] = dateValue(due, allDay: allDay) }
        return ["properties": properties]
    }

    /// Sets (or clears, with nil) a task's date property.
    func setDue(_ task: NotionTask, property: String, to date: Date?, allDay: Bool) async throws {
        try await request("PATCH", "/pages/\(task.id)", body: ["properties": [property: Self.dateValue(date, allDay: allDay)]])
    }

    /// Notion date property value: `{"date": {"start": …}}`, or `{"date": null}` to clear it.
    static func dateValue(_ date: Date?, allDay: Bool) -> [String: Any] {
        guard let date else { return ["date": NSNull()] }
        let start = allDay ? DateParsing.dayString(date) : DateParsing.localRFC3339(date)
        return ["date": ["start": start]]
    }

    static func notDoneFilter(_ rule: DoneRule?) -> [String: Any]? {
        guard let rule else { return nil }
        switch rule.kind {
        case .checkbox:
            return ["property": rule.property, "checkbox": ["equals": false]]
        case .status, .select:
            let clauses = rule.doneOptions.map { ["property": rule.property, rule.kind.rawValue: ["does_not_equal": $0]] }
            return clauses.count == 1 ? clauses[0] : ["and": clauses]
        }
    }

    static func task(from page: [String: Any], db: TaskDatabase, dueProperty: String?, doneRule: DoneRule?) -> NotionTask? {
        guard let id = page["id"] as? String else { return nil }
        if page["archived"] as? Bool == true || page["in_trash"] as? Bool == true { return nil }
        let properties = page["properties"] as? [String: [String: Any]] ?? [:]

        let titleProperty = properties.values.first { $0["type"] as? String == "title" }
        let title = (titleProperty?["title"] as? [[String: Any]] ?? []).compactMap { $0["plain_text"] as? String }.joined()

        var due: Date?, allDay = false
        if let dueProperty,
           let date = properties[dueProperty]?["date"] as? [String: Any],
           let start = date["start"] as? String,
           let parsed = DateParsing.parse(start) {
            (due, allDay) = parsed
        }

        let doneProperty = doneRule.flatMap { properties[$0.property] }
        return NotionTask(
            id: id,
            title: title.isEmpty ? "Untitled" : title,
            due: due,
            dueIsAllDay: allDay,
            isDone: doneRule?.isDone(doneProperty) ?? false,
            originalValue: doneRule.flatMap { DoneRule.optionName(doneProperty, kind: $0.kind) },
            url: (page["url"] as? String).flatMap(URL.init(string:)),
            databaseID: db.id,
            databaseTitle: db.title
        )
    }
}
