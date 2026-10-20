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
    /// Handled by the Chat app (id "chat"): open a new chat on `service` ("chatgpt", "claude", …) with
    /// `text` typed into the message box, not sent.
    static let chatPromptName = "chat.prompt"

    static func chatPrompt(_ text: String, service: String = "chatgpt") -> NotchMessage {
        NotchMessage(name: chatPromptName, payload: ["text": text, "service": service])
    }
}
