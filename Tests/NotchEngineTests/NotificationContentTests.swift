import Foundation
import Testing
import UserNotifications
import NotchKit
@testable import NotchEngine

@Suite struct NotificationContentTests {
    @Test func urgencySetsSoundAndInterruption() {
        let quiet = NotificationRouter.content(for: NotchNotification(title: "Done", urgency: .quiet), appID: "chat")
        #expect(quiet.sound == nil && quiet.interruptionLevel == .passive)
        let urgent = NotificationRouter.content(for: NotchNotification(title: "Allow?", urgency: .urgent), appID: "chat")
        #expect(urgent.sound != nil && urgent.interruptionLevel == .timeSensitive)
    }

    @Test func notificationsAreGroupedAndAddressable() {
        let note = NotchNotification(id: "approval:1", title: "fix-build · Run command", subtitle: "⚠ Force-pushes",
                                     body: "git push -f", payload: ["approval": "1"], thread: "s1")
        let content = NotificationRouter.content(for: note, appID: "chat")
        #expect(content.subtitle == "⚠ Force-pushes" && content.threadIdentifier == "chat:s1")
        #expect(content.userInfo["approval"] as? String == "1" && content.userInfo["notchman.appID"] as? String == "chat")
        #expect(NotificationRouter.identifier(appID: "chat", id: "approval:1") == "chat:approval:1",
                "the same id replaces it, and withdrawing finds it")
    }
}
