import Foundation
import UserNotifications

/// Posts notifications on behalf of notch apps and routes clicks back to the app that posted them.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private static let appKey = "notchman.appID"
    /// Called on the main actor with (appID, payload) when a notification is clicked.
    private let onOpen: @MainActor (String, [String: String]) -> Void

    init(onOpen: @escaping @MainActor (String, [String: String]) -> Void) {
        self.onOpen = onOpen
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func post(appID: String, title: String, body: String, payload: [String: String]) {
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
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
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
        await onOpen(appID, payload)
    }
}
