import WebKit

/// Injected into each chat page: reports when the site starts and stops generating a reply.
///
/// Two signals, either one meaning "writing":
/// - **The reply's stream** (the main one): sites send a reply as a streamed `text/event-stream` response
///   (ChatGPT's `/backend-api/…conversation`, Claude's `…/completion`), which ends exactly when the reply does —
///   even while the page isn't drawing. `streamScript` counts the open ones; it never looks at what they carry.
/// - **The page:** the site's Stop button, or the "thinking" marker reasoning models show instead of it. Only the
///   reply's own Stop controls count, not others named "Stop…" (dictation, voice, sharing).
///
/// Done means both have been quiet for `settle`, so the gaps between a reply's steps (searching, thinking,
/// tools) don't end it early. A reply whose stream was cancelled (you pressed Stop, or switched chats) is
/// reported as `aborted`, which doesn't notify.
/// Posts only `{busy, title, aborted, via}`; it never reads the conversation.
enum ReplyWatcher {
    static let handlerName = "notchmanReply"
    /// How long both signals must be quiet before a reply counts as done (ms).
    static let settle = 1500

    /// Runs in the page's own world before the site's scripts, so it sees the site's `fetch`. Publishes the open
    /// stream count, and how the last one ended, as attributes on <html> for `script` (in NotchMan's world).
    static let streamScript = """
    (() => {
      if (window.__notchmanStreams) return;
      window.__notchmanStreams = true;
      const original = window.fetch;
      if (typeof original !== 'function') return;
      let open = 0;
      const publish = ended => {
        const root = document.documentElement;
        if (!root) return;
        root.setAttribute('data-notchman-streams', String(open));
        if (ended) root.setAttribute('data-notchman-stream-end', ended);
      };
      window.fetch = function (input, init) {
        const pending = original.apply(this, arguments);
        pending.then(response => {
          try {
            const type = (response.headers.get('content-type') || '').toLowerCase();
            if (!type.includes('text/event-stream') || !response.body) return;
            const method = String((init && init.method) || (input && input.method) || 'GET').toUpperCase();
            const url = typeof input === 'string' ? input : String((input && input.url) || input || '');
            // Replies are POSTed; a reply picked up again after a reload is a GET to a …stream URL.
            if (method !== 'POST' && !/stream|resume|completion/i.test(url)) return;
            const reader = response.clone().body.getReader();
            open++;
            publish();
            (async () => {
              let ended = 'complete';
              try { while (!(await reader.read()).done) {} } catch (e) { ended = 'aborted'; }
              open = Math.max(0, open - 1);
              publish(ended);
            })();
          } catch (e) {}
        }, () => {});
        return pending;
      };
    })();
    """

    static let script = """
    (() => {
      if (window.__notchmanReplyWatcher) return;
      window.__notchmanReplyWatcher = true;
      // The reply's own Stop controls, and the marker reasoning models show while thinking without one.
      const replySelectors = [
        '[data-testid="stop-button"]',            // ChatGPT
        'button[data-testid*="stop" i]',          // ChatGPT variants
        'button[aria-label="Stop response"]',     // Claude
        'button[aria-label*="stop answering" i]', // ChatGPT Pro
        'button[aria-label*="stop generating" i]',
        'button[aria-label*="stop streaming" i]',
        '[data-is-streaming="true"]',             // Claude
        '[data-streaming-response-status]',       // ChatGPT thinking
      ];
      // Any other Stop button only counts inside the message box.
      const composerStop = 'form button[aria-label^="stop" i], [data-testid*="composer" i] button[aria-label^="stop" i]';
      const notReply = /record|dictat|voice|shar|listen|read aloud|speak|audio|video|screen|timer/i;
      const isReplyControl = el =>
        !notReply.test(`${el.getAttribute('aria-label') || ''} ${el.getAttribute('data-testid') || ''}`);
      const pageBusy = () => [...replySelectors, composerStop]
        .some(selector => [...document.querySelectorAll(selector)].some(isReplyControl));
      const root = () => document.documentElement;
      const openStreams = () => Number(root().getAttribute('data-notchman-streams') || 0);

      let busy = false, startPath = '', quietSince = 0, timer = null;
      const post = (aborted, via) => window.webkit.messageHandlers.\(handlerName).postMessage(
        { busy, title: document.title || '', aborted, via });
      const check = () => {
        timer = null;
        const streaming = openStreams() > 0, page = pageBusy();
        if (streaming || page) {
          quietSince = 0;
          if (!busy) {
            busy = true;
            startPath = location.pathname;
            post(false, streaming ? 'stream' : 'page');
          }
          return;
        }
        if (!busy) return;
        if (!quietSince) quietSince = Date.now();
        const left = \(settle) - (Date.now() - quietSince);
        if (left > 0) { schedule(left + 50); return; }
        busy = false;
        quietSince = 0;
        // Stopped by hand, or left for another chat: no "replied" for this one.
        const cancelled = root().getAttribute('data-notchman-stream-end') === 'aborted';
        post(cancelled || location.pathname !== startPath, 'quiet');
      };
      const schedule = (delay = 300) => { if (!timer) timer = setTimeout(check, delay); };
      new MutationObserver(() => schedule()).observe(root(), {
        subtree: true, childList: true, attributes: true,
        attributeFilter: ['data-testid', 'aria-label', 'data-is-streaming', 'data-streaming-response-status',
                          'data-notchman-streams'],
      });
      setInterval(check, 1000);
      check();
    })();
    """

    @MainActor static func install(in controller: WKUserContentController, handler: WKScriptMessageHandler) {
        controller.addUserScript(WKUserScript(source: streamScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: .defaultClient))
        controller.add(handler, contentWorld: .defaultClient, name: handlerName)
    }
}

/// What the page reported.
struct ReplyState: Equatable {
    let busy: Bool
    let title: String
    /// The reply ended because its stream was cancelled (Stop, or you left for another chat).
    var aborted = false
    /// What showed it: "stream", "page" (starting), or "quiet" (done).
    var via = ""
}

/// Forwards watcher messages without the content controller retaining the app (it holds handlers strongly).
final class ReplyMessageProxy: NSObject, WKScriptMessageHandler {
    private let onMessage: @MainActor (ReplyState) -> Void

    init(onMessage: @escaping @MainActor (ReplyState) -> Void) {
        self.onMessage = onMessage
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let busy = body["busy"] as? Bool else { return }
        let state = ReplyState(busy: busy, title: body["title"] as? String ?? "",
                               aborted: body["aborted"] as? Bool ?? false, via: body["via"] as? String ?? "")
        MainActor.assumeIsolated { onMessage(state) }
    }
}
