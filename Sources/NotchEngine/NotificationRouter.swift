import Foundation
import NotchKit
import UserNotifications

/// Posts notifications on behalf of notch apps and routes clicks back to the app that posted them.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private static let appKey = "notchman.appID"
    /// Called on the main actor with (appID, payload) when a notification is clicked; an action button adds its
    /// id under "action".
    private let onOpen: @MainActor (String, [String: String]) -> Void
    private let lock = NSLock()
    private var categories: Set<String> = []

    init(onOpen: @escaping @MainActor (String, [String: String]) -> Void) {
        self.onOpen = onOpen
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func post(appID: String, _ notification: NotchNotification) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            } else if settings.authorizationStatus == .denied {
                return
            }
            let content = Self.content(for: notification, appID: appID)
            if !notification.actions.isEmpty {
                content.categoryIdentifier = await register(notification.actions, center: center)
            }
            let identifier = notification.id.map { Self.identifier(appID: appID, id: $0) } ?? UUID().uuidString
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    /// Removes a notification (delivered, or about to be) once it's been dealt with somewhere else.
    func withdraw(appID: String, id: String) {
        let identifier = Self.identifier(appID: appID, id: id)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    static func identifier(appID: String, id: String) -> String { "\(appID):\(id)" }

    static func content(for notification: NotchNotification, appID: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        if let subtitle = notification.subtitle { content.subtitle = subtitle }
        content.body = notification.body
        content.sound = notification.urgency == .quiet ? nil : .default
        content.interruptionLevel = switch notification.urgency {
        case .quiet: .passive
        case .normal: .active
        case .urgent: .timeSensitive
        }
        content.threadIdentifier = notification.thread.map { "\(appID):\($0)" } ?? appID
        var info = notification.payload
        info[appKey] = appID
        content.userInfo = info
        return content
    }

    /// One category per distinct set of buttons, registered alongside those already known.
    private func register(_ actions: [NotchNotificationAction], center: UNUserNotificationCenter) async -> String {
        let id = "notchman." + actions.map { $0.id + ($0.textInput == nil ? "" : "+text") }.joined(separator: ".")
        let isNew = lock.withLock { categories.insert(id).inserted }
        if isNew {
            let category = UNNotificationCategory(
                identifier: id,
                actions: actions.map { action -> UNNotificationAction in
                    let options: UNNotificationActionOptions = action.isDestructive ? [.destructive] : []
                    if let placeholder = action.textInput {
                        return UNTextInputNotificationAction(identifier: action.id, title: action.title, options: options,
                                                             textInputButtonTitle: action.title, textInputPlaceholder: placeholder)
                    }
                    return UNNotificationAction(identifier: action.id, title: action.title, options: options)
                },
                intentIdentifiers: [])
            let existing = await center.notificationCategories()
            center.setNotificationCategories(existing.filter { $0.identifier != id }.union([category]))
        }
        return id
    }

    // Show banners even though NotchMan's notch panel counts as part of the app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        var payload: [String: String] = [:]
        for case let (key as String, value as String) in response.notification.request.content.userInfo {
            payload[key] = value
        }
        guard let appID = payload.removeValue(forKey: Self.appKey) else { return }
        let action = response.actionIdentifier
        if action != UNNotificationDefaultActionIdentifier && action != UNNotificationDismissActionIdentifier {
            payload["action"] = action
        }
        if let reply = (response as? UNTextInputNotificationResponse)?.userText { payload["reply"] = reply }
        await onOpen(appID, payload)
    }
}
