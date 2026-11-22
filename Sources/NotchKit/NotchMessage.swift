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

/// A button on a notification (e.g. Allow / Deny).
public struct NotchNotificationAction: Sendable, Hashable {
    public let id: String
    public let title: String
    public let isDestructive: Bool
    /// Makes it a reply field with this placeholder; the typed text arrives under `"reply"` in the payload.
    public let textInput: String?

    public init(id: String, title: String, isDestructive: Bool = false, textInput: String? = nil) {
        self.id = id
        self.title = title
        self.isDestructive = isDestructive
        self.textInput = textInput
    }
}

/// A macOS notification from a notch app: short, replaceable, and withdrawn once it's been dealt with.
public struct NotchNotification: Sendable {
    public enum Urgency: Sendable {
        /// Delivered silently (something finished).
        case quiet
        /// With a sound.
        case normal
        /// With a sound, and through Focus where allowed (someone is waiting on you).
        case urgent
    }

    /// A later notification with the same id replaces this one, and `withdrawNotification(id:)` removes it.
    public var id: String?
    public var title: String
    public var subtitle: String?
    public var body: String
    public var payload: [String: String]
    public var actions: [NotchNotificationAction]
    public var urgency: Urgency
    /// Groups notifications in Notification Center (e.g. one thread per session).
    public var thread: String?

    public init(id: String? = nil, title: String, subtitle: String? = nil, body: String = "", payload: [String: String] = [:],
                actions: [NotchNotificationAction] = [], urgency: Urgency = .normal, thread: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.payload = payload
        self.actions = actions
        self.urgency = urgency
        self.thread = thread
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
    /// Handled by Today ("today"): put the cursor in its quick-add field.
    static let focusQuickAddName = "quickadd.focus"

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
