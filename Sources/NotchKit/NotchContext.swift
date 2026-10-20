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
    private let visibleHandler: () -> Bool
    private let notifyHandler: (String, String, [String: String]) -> Void
    private let holdHandler: (Bool) -> Void

    public init(
        appID: String,
        attention: @escaping (NotchAttention) -> Void,
        openSettings: @escaping () -> Void,
        send: @escaping (NotchMessage, String) -> Void = { _, _ in },
        isVisible: @escaping () -> Bool = { false },
        notify: @escaping (String, String, [String: String]) -> Void = { _, _, _ in },
        holdOpen: @escaping (Bool) -> Void = { _ in }
    ) {
        self.appID = appID
        self.defaults = UserDefaults(suiteName: "com.notchman.app.\(appID)") ?? .standard
        self.keychain = Keychain(service: "com.notchman.app.\(appID)")
        self.logger = Logger(subsystem: "com.notchman", category: appID)
        self.attentionHandler = attention
        self.openSettingsHandler = openSettings
        self.sendHandler = send
        self.visibleHandler = isVisible
        self.notifyHandler = notify
        self.holdHandler = holdOpen
    }

    /// While held, the notch stays expanded on this app when the mouse wanders off (e.g. while typing in a
    /// terminal); a click outside the notch still closes it.
    public func holdOpen(_ hold: Bool) {
        holdHandler(hold)
    }

    /// Whether this app is on screen right now (selected in an expanded notch).
    public var isVisible: Bool { visibleHandler() }

    /// Posts a macOS notification (asking for permission the first time). Clicking it brings this app up in
    /// the notch and calls `receive(_:)` with `NotchMessage.notificationOpened` carrying `payload`.
    public func notify(title: String, body: String, payload: [String: String] = [:]) {
        notifyHandler(title, body, payload)
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
