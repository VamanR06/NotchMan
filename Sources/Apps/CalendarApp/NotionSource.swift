import Foundation
import NotchKit
import SwiftUI

/// Dated pages from Notion databases, via the free Notion API and an internal integration token.
/// Databases must be shared with the integration (… menu → Connections) to be visible.
@MainActor @Observable
final class NotionSource {
    struct DatabaseInfo: Identifiable, Hashable {
        let id: String
        let title: String
        /// Names of the database's date properties.
        let dateProperties: [String]
    }

    enum NotionError: LocalizedError {
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): "Notion API error \(code): \(body.prefix(200))"
            }
        }
    }

    private static let apiVersion = "2022-06-28"

    private(set) var databases: [DatabaseInfo] = []
    private(set) var hasToken: Bool
    /// Enabled database ID → date property used to place its pages on the timeline.
    var selection: [String: String] {
        didSet { defaults.set(selection, forKey: "notion.selection") }
    }

    @ObservationIgnored private let keychain: Keychain
    @ObservationIgnored private let defaults: UserDefaults

    init(keychain: Keychain, defaults: UserDefaults) {
        self.keychain = keychain
        self.defaults = defaults
        self.hasToken = keychain.string(for: "notion.token") != nil
        self.selection = defaults.dictionary(forKey: "notion.selection") as? [String: String] ?? [:]
    }

    func setToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        keychain.set(trimmed?.isEmpty == false ? trimmed : nil, for: "notion.token")
        hasToken = keychain.string(for: "notion.token") != nil
        if !hasToken {
            databases = []
            selection = [:]
        }
    }

    // MARK: - API

    private func request(_ method: String, _ path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let token = keychain.string(for: "notion.token") else { return [:] }
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

    /// Lists databases shared with the integration.
    func loadDatabases() async throws {
        var found: [DatabaseInfo] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = [
                "filter": ["property": "object", "value": "database"],
                "page_size": 100,
            ]
            if let cursor { body["start_cursor"] = cursor }
            let response = try await request("POST", "/search", body: body)
            for db in response["results"] as? [[String: Any]] ?? [] {
                guard let id = db["id"] as? String else { continue }
                let properties = db["properties"] as? [String: [String: Any]] ?? [:]
                let dateProps = properties.filter { $0.value["type"] as? String == "date" }.keys.sorted()
                found.append(DatabaseInfo(id: id, title: Self.plainText(db["title"]) ?? "Untitled", dateProperties: dateProps))
            }
            cursor = (response["has_more"] as? Bool == true) ? response["next_cursor"] as? String : nil
        } while cursor != nil
        databases = found.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func items(from start: Date, to end: Date) async throws -> [CalendarItem] {
        guard hasToken, !selection.isEmpty else { return [] }
        if databases.isEmpty { try await loadDatabases() }

        var result: [CalendarItem] = []
        for (databaseID, property) in selection {
            let dbName = databases.first { $0.id == databaseID }?.title ?? "Notion"
            let response = try await request("POST", "/databases/\(databaseID)/query", body: [
                "filter": ["and": [
                    ["property": property, "date": ["on_or_after": DateParsing.rfc3339(start)]],
                    ["property": property, "date": ["before": DateParsing.rfc3339(end)]],
                ]],
                "sorts": [["property": property, "direction": "ascending"]],
                "page_size": 100,
            ])
            for page in response["results"] as? [[String: Any]] ?? [] {
                let properties = page["properties"] as? [String: [String: Any]] ?? [:]
                guard let id = page["id"] as? String,
                      let date = properties[property]?["date"] as? [String: Any],
                      let startString = date["start"] as? String,
                      let (startDate, allDay) = DateParsing.parse(startString) else { continue }
                let title = properties.values.first { $0["type"] as? String == "title" }
                    .flatMap { Self.plainText($0["title"]) }
                result.append(CalendarItem(
                    id: "notion:\(id)",
                    title: title?.isEmpty == false ? title! : "Untitled",
                    start: startDate,
                    end: (date["end"] as? String).flatMap { DateParsing.parse($0)?.0 },
                    isAllDay: allDay,
                    color: Color(white: 0.85),
                    source: .notion(databaseName: dbName),
                    url: (page["url"] as? String).flatMap(URL.init(string:)),
                    meetingURL: nil,
                    location: nil
                ))
            }
        }
        return result
    }

    /// Joins a Notion rich-text array into plain text.
    private static func plainText(_ value: Any?) -> String? {
        guard let parts = value as? [[String: Any]] else { return nil }
        return parts.compactMap { $0["plain_text"] as? String }.joined()
    }
}
