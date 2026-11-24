import AppKit
import UserNotifications

/// Keeps NotchMan to one running copy.
///
/// Clicking a NotchMan notification asks macOS for "the app with NotchMan's bundle id". With several builds of it on
/// disk (one per worktree), macOS can launch another copy instead of answering the one that's running, and you'd get
/// a second notch. That copy finds the running one, passes the click over, and quits without starting a notch.
public enum SingleInstance {
    /// Another NotchMan that's already running, if any.
    @MainActor public static func otherInstance() -> NSRunningApplication? {
        let me = NSRunningApplication.current
        guard let id = me.bundleIdentifier ?? Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
    }

    /// The distributed notification a second copy sends the running one with a notification click.
    static let handoffName = Notification.Name("com.notchman.NotchMan.notificationClicked")

    /// Run by the second copy instead of starting a notch: forwards the notification click macOS launched it for
    /// (if any) to the running copy, then quits.
    @MainActor public static func handOff(to running: NSRunningApplication) {
        let forwarder = Forwarder()
        UNUserNotificationCenter.current().delegate = forwarder
        retained = forwarder
        // A click macOS launched us for arrives just after launch; without one there's nothing to pass on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
    }

    @MainActor private static var retained: Forwarder?

    private final class Forwarder: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            if var info = NotificationRouter.userInfo(of: response) {
                // Only a plain click (it opens the right app); button actions and replies, which act on Claude,
                // are never taken from a broadcast another process could also send.
                info.removeValue(forKey: "action")
                info.removeValue(forKey: "reply")
                DistributedNotificationCenter.default().postNotificationName(
                    handoffName, object: nil, userInfo: info, deliverImmediately: true)
            }
            await MainActor.run { NSApp.terminate(nil) }
        }
    }
}
