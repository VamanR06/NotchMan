import AppKit
import Foundation
import Testing
import WebKit
@testable import ChatApp

/// Runs the reply watcher on a stand-in chat page whose `fetch` returns streams the test opens, ends and cancels.
@MainActor @Suite(.serialized) struct ReplyWatcherTests {
    @MainActor final class Page {
        let web: WKWebView
        let window: NSWindow
        var states: [ReplyState] = []

        init(body: String = "") async throws {
            web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            // Stands in for the site's network before the watcher wraps it (as the real fetch would be).
            web.configuration.userContentController.addUserScript(WKUserScript(source: """
            const controllers = [];
            window.fetch = (url, init) => {
              const stream = new ReadableStream({ start(c) {
                controllers.push(c);
                c.enqueue(new TextEncoder().encode('data: {}\\n\\n'));
              } });
              const type = String(url).includes('json') ? 'application/json' : 'text/event-stream';
              return Promise.resolve(new Response(stream, { headers: { 'content-type': type } }));
            };
            window.__end = () => controllers.shift().close();
            window.__cancel = () => controllers.shift().error(new DOMException('cancelled', 'AbortError'));
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
            window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = web
            ReplyWatcher.install(in: web.configuration.userContentController,
                                 handler: ReplyMessageProxy { [weak self] in self?.states.append($0) })
            web.loadHTMLString("<html><head><title>Trip plan</title></head><body><form id=\"composer\"></form>\(body)</body></html>",
                               baseURL: URL(string: "https://chatgpt.com/c/1"))
            for _ in 0..<60 where web.isLoading { try await Task.sleep(for: .milliseconds(50)) }
            try await Task.sleep(for: .milliseconds(300))
        }

        func js(_ source: String) async throws {
            _ = try await web.callAsyncJavaScript(source + "; return true;", arguments: [:], in: nil, contentWorld: .page)
        }

        func send(_ url: String = "/backend-api/f/conversation", method: String = "POST") async throws {
            try await js("fetch('\(url)', { method: '\(method)' })")
        }

        /// Waits until `count` states were reported (or the time runs out).
        func wait(for count: Int, seconds: Double = 4) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while states.count < count && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        }

        func close() { window.close() }
    }

    @Test func theReplysStreamStartsAndEndsIt() async throws {
        let page = try await Page()
        defer { page.close() }
        try await page.send()
        try await page.wait(for: 1)
        #expect(page.states == [ReplyState(busy: true, title: "Trip plan", via: "stream")])
        try await page.js("__end()")
        try await page.wait(for: 2)
        #expect(page.states.last == ReplyState(busy: false, title: "Trip plan", aborted: false, via: "quiet"))
    }

    @Test func aPauseBetweenStepsDoesntEndTheReply() async throws {
        let page = try await Page()
        defer { page.close() }
        try await page.send()
        try await page.wait(for: 1)
        try await page.js("__end()")
        try await Task.sleep(for: .milliseconds(600))
        try await page.send()  // the next step (after a search, say)
        try await Task.sleep(for: .milliseconds(ReplyWatcher.settle + 500))
        #expect(page.states.map(\.busy) == [true], "still one reply, still writing")
        try await page.js("__end()")
        try await page.wait(for: 2)
        #expect(page.states.map(\.busy) == [true, false])
    }

    @Test func aCancelledStreamDoesntCountAsAReply() async throws {
        let page = try await Page()
        defer { page.close() }
        try await page.send()
        try await page.wait(for: 1)
        try await page.js("__cancel()")
        try await page.wait(for: 2)
        #expect(page.states.last?.busy == false && page.states.last?.aborted == true)
    }

    @Test func otherRequestsAndOtherStopButtonsDontCount() async throws {
        let page = try await Page(body: """
        <button aria-label="Stop recording">●</button>
        <button data-testid="stop-dictation-button" aria-label="Stop dictation">■</button>
        <button aria-label="Stop sharing">×</button>
        """)
        defer { page.close() }
        try await page.send("/backend-api/settings.json")         // not a stream
        try await page.send("/backend-api/notifications", method: "GET")  // a GET stream that isn't a reply
        try await Task.sleep(for: .milliseconds(1500))
        #expect(page.states.isEmpty)
    }

    @Test func theThinkingMarkerCountsWithoutAStopButton() async throws {
        let page = try await Page()
        defer { page.close() }
        try await page.js("""
        const status = document.createElement('div');
        status.setAttribute('data-streaming-response-status', 'thinking');
        status.id = 'thinking';
        document.body.appendChild(status)
        """)
        try await page.wait(for: 1)
        #expect(page.states.first == ReplyState(busy: true, title: "Trip plan", via: "page"))
        try await page.js("document.getElementById('thinking').remove()")
        try await page.wait(for: 2)
        #expect(page.states.last?.busy == false && page.states.last?.aborted == false)
    }

    @Test func leavingForAnotherChatIsntAReply() async throws {
        let page = try await Page()
        defer { page.close() }
        try await page.js("""
        const stop = document.createElement('button');
        stop.setAttribute('data-testid', 'stop-button');
        stop.id = 'stop';
        document.getElementById('composer').appendChild(stop)
        """)
        try await page.wait(for: 1)
        try await page.js("history.pushState({}, '', '/c/2'); document.getElementById('stop').remove()")
        try await page.wait(for: 2)
        #expect(page.states.last?.busy == false && page.states.last?.aborted == true)
    }
}
