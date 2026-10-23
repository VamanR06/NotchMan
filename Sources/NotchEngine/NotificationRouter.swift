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

    func post(appID: String, title: String, body: String, payload: [String: String], actions: [NotchNotificationAction] = []) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            } else if settings.authorizationStatus == .denied {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            var info: [String: String] = payload
            info[Self.appKey] = appID
            content.userInfo = info
            if !actions.isEmpty { content.categoryIdentifier = await register(actions, center: center) }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// One category per distinct set of buttons, registered alongside those already known.
    private func register(_ actions: [NotchNotificationAction], center: UNUserNotificationCenter) async -> String {
        let id = "notchman." + actions.map(\.id).joined(separator: ".")
        let isNew = lock.withLock { categories.insert(id).inserted }
        if isNew {
            let category = UNNotificationCategory(
                identifier: id,
                actions: actions.map { UNNotificationAction(identifier: $0.id, title: $0.title,
                                                            options: $0.isDestructive ? [.destructive] : []) },
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
        await onOpen(appID, payload)
    }
}
