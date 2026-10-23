import AppKit
import Testing
@testable import NotchKit

@MainActor @Suite struct AskAITests {
    @Test func templateWrapsTheItem() {
        let ai = AskAI()
        #expect(ai.prompt(for: "Task: Ship it") == "Help me with this:\n\nTask: Ship it")
        ai.promptTemplate = "What should I do about {item}?"
        #expect(ai.prompt(for: "X") == "What should I do about X?")
        ai.promptTemplate = "No placeholder"
        #expect(ai.prompt(for: "X") == "No placeholder\n\nX")
    }

    @Test func askSendsAChatPromptToTheProject() {
        let ai = AskAI()
        var sent: NotchMessage?
        ai.deliver = { sent = $0 }
        ai.ask("Event: Standup", service: "claude", project: AskProject(name: "Work", url: "https://claude.ai/project/1"))
        #expect(sent?.name == NotchMessage.chatPromptName)
        #expect(sent?.payload["service"] == "claude")
        #expect(sent?.payload["url"] == "https://claude.ai/project/1")
        #expect(sent?.payload["text"] == "Help me with this:\n\nEvent: Standup")
    }

    @Test func defaultProjectLookup() {
        let p = AskProject(name: "Jobs", url: "https://chatgpt.com/g/g-p-1/project")
        #expect(AskService(id: "chatgpt", name: "ChatGPT", projects: [p], defaultProjectURL: p.url).defaultProject == p)
        #expect(AskService(id: "chatgpt", name: "ChatGPT", projects: [p]).defaultProject == nil)
    }
}

@MainActor @Suite struct NotchFocusTests {
    @Test func convertsCocoaPointsToWindowCoordinates() {
        #expect(NotchFocus.cgCoordinates(CGPoint(x: 100, y: 1000), mainDisplayHeight: 1080) == CGPoint(x: 100, y: 80))
        #expect(NotchFocus.cgCoordinates(CGPoint(x: 2400, y: 1080), mainDisplayHeight: 1080) == CGPoint(x: 2400, y: 0))
    }

    @Test func knowsTheSystemPasswordHelpers() {
        #expect(NotchFocus.systemHelperBundleIDs.contains("com.apple.AutoFillPanelService"))
        #expect(NotchFocus.systemHelperBundleIDs.contains("com.apple.LocalAuthentication.UIAgent"))
        #expect(!NotchFocus.systemHelperBundleIDs.contains("com.google.Chrome"))
    }

    @Test func findsTheOwnerOfAWindowUnderThePointer() throws {
        // Some app's window is under the middle of the main display in any normal session; it's never NotchMan's
        // test runner (which has no windows), so an owner should come back.
        guard let screen = NSScreen.screens.first else { return }
        let owner = NotchFocus.otherAppWindowOwner(at: CGPoint(x: screen.frame.midX, y: screen.frame.midY))
        #expect(owner?.processIdentifier != ProcessInfo.processInfo.processIdentifier)
    }
}
