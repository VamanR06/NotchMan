import Foundation
import os

/// Services the engine hands to each app in `activate(context:)`.
@MainActor
public final class NotchContext {
    public let appID: String
    /// Per-app preferences store.
    public let defaults: UserDefaults
    /// Per-app secure storage (tokens, API keys).
    public let keychain: Keychain
    public let logger: Logger

    private let attentionHandler: (NotchAttention) -> Void
    private let openSettingsHandler: () -> Void
    private let sendHandler: (NotchMessage, String) -> Void

    public init(
        appID: String,
        attention: @escaping (NotchAttention) -> Void,
        openSettings: @escaping () -> Void,
        send: @escaping (NotchMessage, String) -> Void = { _, _ in }
    ) {
        self.appID = appID
        self.defaults = UserDefaults(suiteName: "com.notchman.app.\(appID)") ?? .standard
        self.keychain = Keychain(service: "com.notchman.app.\(appID)")
        self.logger = Logger(subsystem: "com.notchman", category: appID)
        self.attentionHandler = attention
        self.openSettingsHandler = openSettings
        self.sendHandler = send
    }

    /// Delivers `message` to the app with id `appID` and shows that app in the notch.
    public func send(_ message: NotchMessage, to appID: String) {
        sendHandler(message, appID)
    }

    public func requestAttention(_ attention: NotchAttention = .pulse) {
        attentionHandler(attention)
    }

    /// Opens the NotchMan settings window on this app's pane.
    public func openSettings() {
        openSettingsHandler()
    }
}
