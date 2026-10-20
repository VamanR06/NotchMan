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

    public init(
        appID: String,
        attention: @escaping (NotchAttention) -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.appID = appID
        self.defaults = UserDefaults(suiteName: "com.notchman.app.\(appID)") ?? .standard
        self.keychain = Keychain(service: "com.notchman.app.\(appID)")
        self.logger = Logger(subsystem: "com.notchman", category: appID)
        self.attentionHandler = attention
        self.openSettingsHandler = openSettings
    }

    public func requestAttention(_ attention: NotchAttention = .pulse) {
        attentionHandler(attention)
    }

    /// Opens the NotchMan settings window on this app's pane.
    public func openSettings() {
        openSettingsHandler()
    }
}
