import AppKit
import Foundation
import Testing
import WebKit
@testable import ChatApp

/// Runs the reply watcher on a stand-in ChatGPT page whose `fetch` returns streams the test opens, ends and cancels.
@MainActor @Suite(.serialized) struct ReplyWatcherTests {
    static let chatA = "/c/aaaa1111-0000"
    static let chatB = "/c/bbbb2222-0000"

    @MainActor final class Page {
        let web: WKWebView
        let window: NSWindow
        var events: [ReplyEvent] = []
        var states: [ReplyState] { events.compactMap { if case .state(let state) = $0 { state } else { nil } } }

        init(path: String = ReplyWatcherTests.chatA, body: String = "") async throws {
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
            window.__chunk = () => controllers[0].enqueue(new TextEncoder().encode('data: {}\\n\\n'));
            window.__end = () => controllers.shift().close();
            window.__cancel = () => controllers.shift().error(new DOMException('cancelled', 'AbortError'));
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
            window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = web
            ReplyWatcher.install(in: web.configuration.userContentController, service: .chatgpt,
                                 handler: ReplyMessageProxy { [weak self] in self?.events.append($0) })
            web.loadHTMLString("<html><head><title>Trip plan</title></head><body><form id=\"composer\"></form>\(body)</body></html>",
                               baseURL: URL(string: "https://chatgpt.com\(path)"))
            for _ in 0..<60 where web.isLoading { try await Task.sleep(for: .milliseconds(50)) }
            try await Task.sleep(for: .milliseconds(300))
        }

        func js(_ source: String) async throws {
            _ = try await web.callAsyncJavaScript(source + "; return true;", arguments: [:], in: nil, contentWorld: .page)
        }

        func send(_ url: String = "/backend-api/f/conversation", method: String = "POST") async throws {
            try await js("fetch('\(url)', { method: '\(method)' })")
        }

        func go(to path: String) async throws { try await js("history.pushState({}, '', '\(path)')") }

        /// Waits until `count` events were reported (or the time runs out).
        func wait(for count: Int, seconds: Double = 4) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while events.count < count && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        }

        func close() { window.close() }
    }

    @Test func theReplysStreamStartsAndEndsIt() async throws {
        let page = try await Page()
        defer { page.close() }
        try await page.send()
        try await page.wait(for: 1)
        #expect(page.states == [ReplyState(busy: true, title: "Trip plan", path: Self.chatA, via: "stream")])
        try await page.js("__end()")
        try await page.wait(for: 2)
        #expect(page.states.last == ReplyState(busy: false, title: "Trip plan", path: Self.chatA, via: "quiet"))
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

    @Test func stoppingAReplyDoesntCountAsOne() async throws {
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
        try await page.send("/backend-api/settings.json")                  // not a stream
        try await page.send("/backend-api/notifications", method: "GET")   // a GET stream that isn't a reply
        try await Task.sleep(for: .milliseconds(1500))
        #expect(page.events.isEmpty)
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
        #expect(page.states.first == ReplyState(busy: true, title: "Trip plan", path: Self.chatA, via: "page"))
        try await page.js("document.getElementById('thinking').remove()")
        try await page.wait(for: 2)
        #expect(page.states.last?.busy == false && page.states.last?.aborted == false)
    }

    @Test func leavingMidReplyThenItsStreamFinishing() async throws {
        let page = try await Page()
        defer { page.close() }
        try await page.send()
        try await page.wait(for: 1)
        try await page.go(to: Self.chatB)
        try await page.wait(for: 2)
        #expect(page.states.last == ReplyState(busy: false, title: "Trip plan", path: Self.chatA, left: true,
                                               streamOpen: true, via: "left"))
        // Chat B isn't writing just because A's stream is still open.
        try await Task.sleep(for: .milliseconds(1200))
        #expect(page.states.count == 2)
        try await page.js("__end()")
        try await page.wait(for: 3)
        #expect(page.events.last == .elsewhere(path: Self.chatA, reason: "complete"))
    }

    @Test func leavingCutsTheStream() async throws {
        let page = try await Page()
        defer { page.close() }
        try await page.send()
        try await page.wait(for: 1)
        try await page.js("history.pushState({}, '', '\(Self.chatB)'); __cancel()")
        try await page.wait(for: 3)
        #expect(page.states.last?.left == true && page.states.last?.path == Self.chatA)
        #expect(page.events.contains(.elsewhere(path: Self.chatA, reason: "aborted")))
    }

    @Test func aNewChatTakingItsAddressIsntLeaving() async throws {
        let page = try await Page(path: "/")
        defer { page.close() }
        try await page.send()
        try await page.wait(for: 1)
        try await page.go(to: "/c/cccc3333-0000")  // the site gives the new chat its address mid-reply
        try await page.js("__chunk()")
        try await Task.sleep(for: .milliseconds(1200))
        #expect(page.states.map(\.busy) == [true])
        try await page.js("__end()")
        try await page.wait(for: 2)
        #expect(page.states.last == ReplyState(busy: false, title: "Trip plan", path: "/c/cccc3333-0000", via: "quiet"))
    }
}

@MainActor @Suite struct BackgroundWatchLimitTests {
    @Test func followsUpToTheLimitAndStopsTheOldest() throws {
        let app = ChatApp()
        app.maxBackgroundWatches = 2
        let chats = ["aaaa1111-0001", "aaaa1111-0002", "aaaa1111-0003"]
        for id in chats { app.followInBackground(.chatgpt, url: try #require(URL(string: "https://chatgpt.com/c/\(id)"))) }
        #expect(app.writingChats == ["chatgpt:aaaa1111-0002", "chatgpt:aaaa1111-0003"])
        app.maxBackgroundWatches = 1
        #expect(app.writingChats == ["chatgpt:aaaa1111-0003"])
        app.maxBackgroundWatches = 0
        #expect(app.writingChats.isEmpty)
        app.followInBackground(.chatgpt, url: try #require(URL(string: "https://chatgpt.com/c/\(chats[0])")))
        #expect(app.writingChats.isEmpty, "off: nothing followed")
    }
}

/// Follows a reply in a hidden page, on stand-in pages served from disk.
@MainActor @Suite(.serialized) struct BackgroundReplyWatchTests {
    private func page(_ html: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "notchman-reply-\(UUID().uuidString).html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func follow(_ html: String, probe: String = "return null;", timeout: Double = 15) async throws -> (Bool?, TimeInterval) {
        let watch = BackgroundReplyWatch(service: .muse, url: try page(html), userAgent: nil)
        watch.checkEvery = .milliseconds(300)
        watch.quietFor = 1
        watch.neverStartedAfter = 2
        watch.statusStuckAfter = 3
        watch.probeScript = probe
        var result: Bool?
        watch.onDone = { result = $0 }
        let started = Date()
        watch.start()
        while result == nil && Date().timeIntervalSince(started) < timeout { try await Task.sleep(for: .milliseconds(100)) }
        watch.stop()
        return (result, Date().timeIntervalSince(started))
    }

    @Test func waitsForTheResumedReplyToFinish() async throws {
        let (done, took) = try await follow("""
        <html><body><form><button data-testid="stop-button" id="stop">■</button></form>
        <script>setTimeout(() => document.getElementById('stop').remove(), 3000);</script></body></html>
        """)
        #expect(done == true)
        #expect(took >= 3, "not before the Stop button went away")
    }

    @Test func aReplyThatFinishedWhileSwitchingIsDoneSoon() async throws {
        let (done, took) = try await follow("<html><body><p>Finished reply</p></body></html>")
        #expect(done == true)
        #expect(took < 5)
    }

    @Test func theSitesStatusKeepsItWriting() async throws {
        let (done, took) = try await follow("""
        <html><body data-streaming="yes"><script>setTimeout(() => document.body.dataset.streaming = 'no', 3000);</script></body></html>
        """, probe: "return document.body.dataset.streaming === 'yes';")
        #expect(done == true)
        #expect(took >= 3)
    }
}
