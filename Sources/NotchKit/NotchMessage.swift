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

    static func chatPrompt(_ text: String, service: String = "chatgpt", url: String? = nil) -> NotchMessage {
        var payload = ["text": text, "service": service]
        payload["url"] = url
        return NotchMessage(name: chatPromptName, payload: payload)
    }
}
