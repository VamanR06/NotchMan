import AppKit
import Testing
import WebKit
import NotchKit
@testable import NotchEngine

/// Which views count as "typing", so the notch's own keys (Esc, arrows, Return) stay out of their way.
@MainActor @Suite struct TypingDetectionTests {
    private final class FakeTerminal: NSView, NotchTypingView {}
    /// Named like a terminal but not one: the old class-name check counted it as typing.
    private final class TerminalLookalikeButton: NSView {}

    @Test func textFieldsTerminalsAndWebPagesAreTyping() {
        #expect(NotchEngine.isTyping(NSTextView()))
        #expect(NotchEngine.isTyping(FakeTerminal()))
        #expect(NotchEngine.isTyping(WKWebView()))
    }

    @Test func viewsInsideATypingViewAreTyping() {
        let terminal = FakeTerminal()
        let child = NSView()
        terminal.addSubview(child)
        #expect(NotchEngine.isTyping(child))
    }

    @Test func otherViewsAreNot() {
        #expect(!NotchEngine.isTyping(nil))
        #expect(!NotchEngine.isTyping(NSView()))
        #expect(!NotchEngine.isTyping(TerminalLookalikeButton()))
        #expect(!NotchEngine.isTyping(NSButton()))
    }
}
