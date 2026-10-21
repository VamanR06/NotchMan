import AppKit
import SwiftUI
import Testing
import WebKit
@testable import ChatApp

@MainActor @Suite(.serialized) struct ScrollToLatestTests {
    private func load(_ html: String) async throws -> (WKWebView, NSWindow) {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        web.loadHTMLString(html, baseURL: URL(string: "https://chatgpt.com/c/1"))
        for _ in 0..<50 where web.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        return (web, window)
    }

    private func run(_ web: WKWebView, _ js: String) async throws -> Any? {
        try await web.evaluateJavaScript(js, contentWorld: .defaultClient)
    }

    @Test func scrollsTheThreadContainerToTheLastMessage() async throws {
        let turns = (1...60).map { "<article data-testid=\"conversation-turn-\($0)\"><div data-message-author-role=\"assistant\">Message \($0)</div></article>" }.joined()
        let (web, window) = try await load("""
        <html><body style="margin:0"><main><div id="scroller" style="height:380px;overflow-y:auto">\(turns)</div></main></body></html>
        """)
        #expect(try await run(web, "document.getElementById('scroller').scrollTop") as? Double == 0)
        #expect(try await run(web, ChatService.scrollToLatestScript) as? String == "element")
        let atBottom = try await run(web, "(() => { const s = document.getElementById('scroller'); return s.scrollTop + s.clientHeight >= s.scrollHeight - 1; })()")
        #expect(atBottom as? Bool == true)
        window.close()
    }

    @Test func fallsBackToScrollingThePage() async throws {
        let (web, window) = try await load("<html><body>\(String(repeating: "<p>line</p>", count: 200))</body></html>")
        #expect(try await run(web, ChatService.scrollToLatestScript) as? String == "page")
        #expect((try await run(web, "window.scrollY") as? Double ?? 0) > 100)
        window.close()
    }

    @Test func museIsNotScrolled() {
        #expect(ChatService.chatgpt.scrollsToLatest && ChatService.claude.scrollsToLatest && !ChatService.muse.scrollsToLatest)
    }

    @Test func hostAttachesOnlyAtARealSize() async throws {
        let hosted = NSView()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var sawZeroSize = false
        final class Spy: NSView {
            var onResize: ((CGSize) -> Void)?
            override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); onResize?(size) }
        }
        let spy = Spy()
        spy.onResize = { size in if size.width < 1 || size.height < 1 { sawZeroSize = true } }
        _ = hosted
        window.contentView = NSHostingView(rootView: NSViewHost(view: spy).frame(width: 400, height: 300))
        for _ in 0..<10 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
        #expect(spy.window === window)
        #expect(spy.frame.size == CGSize(width: 400, height: 300))
        #expect(!sawZeroSize, "never shown at zero size")
        window.close()
    }
}
