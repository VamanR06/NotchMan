import Foundation

/// A request from one notch app to another, delivered through the engine (apps don't import each other).
/// The receiving app is brought up in the expanded notch.
public struct NotchMessage: Sendable, Equatable {
    public let name: String
    public let payload: [String: String]

    public init(name: String, payload: [String: String] = [:]) {
        self.name = name
        self.payload = payload
    }
}

// MARK: - Well-known messages

public extension NotchMessage {
    /// Delivered to an app when the user clicks one of its notifications; payload is what it posted with.
    static let notificationOpenedName = "notification.opened"

    /// Handled by the Chat app (id "chat"): open a new chat on `service` ("chatgpt", "claude", …) with
    /// `text` typed into the message box, not sent. `url` optionally starts the chat on a page of that
    /// service instead of its home page — e.g. a ChatGPT project, so the chat is saved in that project.
    static let chatPromptName = "chat.prompt"

    /// Handled by Tasks ("tasks") and Calendar ("calendar"): create what a quick-add line described. Sent with
    /// `reveal: false`; the app confirms with a transient.
    static let quickAddTaskName = "quickadd.task"
    static let quickAddEventName = "quickadd.event"

    static func quickAdd(_ item: QuickAdd, asEvent: Bool) -> NotchMessage {
        var payload = ["title": item.title, "hasTime": item.hasTime ? "1" : "0"]
        payload["date"] = item.date.map { String($0.timeIntervalSince1970) }
        payload["duration"] = item.duration.map { String($0) }
        return NotchMessage(name: asEvent ? quickAddEventName : quickAddTaskName, payload: payload)
    }

    /// The quick-add item a `quickAdd` message carries.
    var quickAdd: QuickAdd? {
        guard let title = payload["title"] else { return nil }
        return QuickAdd(title: title,
                        date: payload["date"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
                        hasTime: payload["hasTime"] == "1",
                        duration: payload["duration"].flatMap(Double.init))
    }

    static func chatPrompt(_ text: String, service: String = "chatgpt", url: String? = nil) -> NotchMessage {
        var payload = ["text": text, "service": service]
        payload["url"] = url
        return NotchMessage(name: chatPromptName, payload: payload)
    }
}
