import AppKit
import WebKit

/// Follows a reply in a conversation you left mid-reply, so you still hear when it's done.
///
/// The sites keep writing after you leave (ChatGPT and Claude both finish the reply on their side, and a reopened
/// chat picks it back up), so this opens the conversation in a hidden, desktop-width copy of the site (sharing
/// your sign-in) and watches it there, until the reply is done or `giveUpAfter`. "Writing" is any of:
/// - the page's own signals (`ReplyWatcher`: the resumed reply stream, the Stop button, the thinking marker)
/// - `ChatService.replyProbeScript`: ChatGPT's stream status for the conversation; Claude's "still creating a
///   response in the background" note
@MainActor
final class BackgroundReplyWatch: NSObject, WKNavigationDelegate {
    let service: ChatService
    let url: URL
    /// Called once: `true` when the reply finished, `false` when it gave up (you'll see it when you open it).
    var onDone: ((Bool) -> Void)?

    /// Never writing this long after loading: the reply finished while you were switching.
    var neverStartedAfter: TimeInterval = 12
    /// Quiet this long after writing: done.
    var quietFor: TimeInterval = 4
    /// The page went quiet but the site's status still says writing: after this long, believe the page (ChatGPT's
    /// status has been seen stuck on "streaming" after a reply ended).
    var statusStuckAfter: TimeInterval = 45
    var giveUpAfter: TimeInterval = 15 * 60
    var checkEvery: Duration = .seconds(2)
    /// Asks the site whether it's still writing (see `ChatService.replyProbeScript`).
    lazy var probeScript = service.replyProbeScript

    private let userAgent: String?
    private var webView: WKWebView?
    private var window: NSWindow?
    private var task: Task<Void, Never>?
    private var pageBusy = false

    init(service: ChatService, url: URL, userAgent: String?) {
        self.service = service
        self.url = url
        self.userAgent = userAgent
    }

    func start() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // same cookies as the notch's page
        ReplyWatcher.install(in: config.userContentController, service: service,
                             handler: ReplyMessageProxy { [weak self] event in
            if case .state(let state) = event, !state.left { self?.pageBusy = state.busy }
        })
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        view.customUserAgent = userAgent
        view.navigationDelegate = self
        // Offscreen window so the page runs as if visible (hidden pages are throttled).
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 1280, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        webView = view
        self.window = window
        view.load(URLRequest(url: url))
        task = Task { [weak self] in await self?.watch() }
    }

    private func watch() async {
        let started = Date()
        var loadedAt: Date?
        var sawWriting = false
        /// When the page last showed writing (nil: never).
        var pageLastBusy: Date?
        /// Since when nothing has said writing.
        var quietSince: Date?
        while !Task.isCancelled, Date().timeIntervalSince(started) < giveUpAfter {
            try? await Task.sleep(for: checkEvery)
            guard let view = webView, !Task.isCancelled else { return }
            if view.isLoading { continue }
            let now = Date()
            let loaded = loadedAt ?? now
            loadedAt = loaded
            let raw = try? await view.callAsyncJavaScript(probeScript, arguments: [:], in: nil,
                                                          contentWorld: .defaultClient)
            let status = raw as? Bool  // nil: the site didn't say
            if pageBusy {
                sawWriting = true
                pageLastBusy = now
                quietSince = nil
            } else if status == true {
                sawWriting = true
                quietSince = nil
                // Only the site's status still says writing; after a while of the page saying otherwise, believe
                // the page.
                if let last = pageLastBusy, now.timeIntervalSince(last) >= statusStuckAfter { return finish(true) }
            } else if sawWriting {
                let quiet = quietSince ?? now
                quietSince = quiet
                if now.timeIntervalSince(quiet) >= quietFor { return finish(true) }
            } else if now.timeIntervalSince(loaded) >= neverStartedAfter {
                return finish(true)
            }
        }
        if !Task.isCancelled { finish(false) }
    }

    private func finish(_ finished: Bool) {
        let done = onDone
        onDone = nil
        stop()
        done?(finished)
    }

    /// Closes the hidden page without reporting (e.g. you opened the conversation again).
    func stop() {
        task?.cancel()
        task = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        window?.close()
        webView = nil
        window = nil
    }
}

extension ChatService {
    /// Asks the site whether the conversation on the page is still being written: true / false, or null when it
    /// can't tell (then the page's own signals decide).
    var replyProbeScript: String {
        switch self {
        case .chatgpt:
            """
            const match = location.pathname.match(/\\/c\\/([A-Za-z0-9-]+)/);
            if (!match) return null;
            try {
              if (!window.__notchmanToken) {
                const session = await (await fetch('/api/auth/session', { credentials: 'include' })).json();
                window.__notchmanToken = session && session.accessToken;
              }
              if (!window.__notchmanToken) return null;
              const response = await fetch(`/backend-api/conversation/${match[1]}/stream_status`,
                { credentials: 'include', headers: { Authorization: 'Bearer ' + window.__notchmanToken } });
              if (!response.ok) return null;
              const body = await response.json();
              if (!body || typeof body.status !== 'string') return null;
              return body.status === 'IS_STREAMING';
            } catch (e) { return null; }
            """
        case .claude:
            """
            const text = (document.body && document.body.innerText) || '';
            if (/still creating a response in the background|checking for a response to your message/i.test(text)) return true;
            return null;
            """
        case .muse:
            "return null;"
        }
    }
}
