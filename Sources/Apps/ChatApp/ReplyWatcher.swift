import WebKit

/// Injected into each chat page: reports when the site starts and stops generating a reply, per conversation.
///
/// Two signals, either one meaning "writing":
/// - **The reply's stream** (the main one): sites send a reply as a streamed `text/event-stream` response
///   (ChatGPT's `/backend-api/…conversation`, Claude's `…/completion`), which ends exactly when the reply does —
///   even while the page isn't drawing. `streamScript` tracks the open ones and which conversation each belongs
///   to; it never looks at what they carry.
/// - **The page:** the site's Stop button, or the "thinking" marker reasoning models show instead of it. Only the
///   reply's own Stop controls count, not others named "Stop…" (dictation, voice, sharing).
///
/// Done means both have been quiet for `settle`, so the gaps between a reply's steps (searching, thinking,
/// tools) don't end it early. A reply whose stream was cancelled while you stayed (you pressed Stop) is
/// `aborted`. Leaving a conversation mid-reply reports `left` (the app keeps watching it), and a stream that
/// ends in a conversation you've left reports `elsewhere`.
/// Posts only states, paths and titles; it never reads the conversation.
enum ReplyWatcher {
    static let handlerName = "notchmanReply"
    /// How long both signals must be quiet before a reply counts as done (ms).
    static let settle = 1500

    /// Runs in the page's own world before the site's scripts, so it sees the site's `fetch`. Publishes the open
    /// streams' conversations, and how recent ones ended, as attributes on <html> for `script` (NotchMan's world).
    static func streamScript(for service: ChatService) -> String {
        """
        (() => {
          if (window.__notchmanStreams) return;
          window.__notchmanStreams = true;
          const original = window.fetch;
          if (typeof original !== 'function') return;
          const isChat = path => \(service.conversationPathPattern).test(path || '');
          const open = new Map(), ended = [];
          let next = 0, seq = 0;
          const publish = () => {
            const root = document.documentElement;
            if (!root) return;
            root.setAttribute('data-notchman-streams', JSON.stringify([...open.values()]));
            root.setAttribute('data-notchman-stream-ends', JSON.stringify(ended));
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
                const id = next++;
                open.set(id, location.pathname);
                publish();
                (async () => {
                  let reason = 'complete';
                  try {
                    for (;;) {
                      if ((await reader.read()).done) break;
                      // A new chat gets its address once the reply starts: follow it there.
                      if (!isChat(open.get(id)) && isChat(location.pathname)) {
                        open.set(id, location.pathname);
                        publish();
                      }
                    }
                  } catch (e) { reason = 'aborted'; }
                  ended.push({ seq: ++seq, reason, path: open.get(id) });
                  if (ended.length > 10) ended.shift();
                  open.delete(id);
                  publish();
                })();
              } catch (e) {}
            }, () => {});
            return pending;
          };
        })();
        """
    }

    static func script(for service: ChatService) -> String {
        """
        (() => {
          if (window.__notchmanReplyWatcher) return;
          window.__notchmanReplyWatcher = true;
          const isChat = path => \(service.conversationPathPattern).test(path || '');
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
          const read = name => { try { return JSON.parse(root().getAttribute(name) || '[]'); } catch (e) { return []; } };

          let busy = false, startPath = '', quietSince = 0, timer = null, lastSeq = 0, endedHere = '';
          const post = message => window.webkit.messageHandlers.\(handlerName).postMessage(
            Object.assign({ kind: 'state', title: document.title || '' }, message));
          const check = () => {
            timer = null;
            const here = location.pathname, streams = read('data-notchman-streams');
            if (busy && here !== startPath) {
              if (!isChat(startPath)) {
                startPath = here;  // the site gave the new chat its address
              } else {
                // You left mid-reply; the app follows that conversation from here.
                post({ busy: false, left: true, path: startPath, streamOpen: streams.includes(startPath), via: 'left' });
                busy = false;
                quietSince = 0;
              }
            }
            for (const end of read('data-notchman-stream-ends')) {
              if (end.seq <= lastSeq) continue;
              lastSeq = end.seq;
              if (end.path !== here && isChat(end.path)) {
                post({ kind: 'elsewhere', path: end.path, reason: end.reason });
              } else {
                endedHere = end.reason;
              }
            }
            const streaming = streams.some(path => path === here || !isChat(path)), page = pageBusy();
            if (streaming || page) {
              quietSince = 0;
              if (!busy) {
                busy = true;
                startPath = here;
                endedHere = '';
                post({ busy: true, path: here, via: streaming ? 'stream' : 'page' });
              }
              return;
            }
            if (!busy) return;
            if (!quietSince) quietSince = Date.now();
            const left = \(settle) - (Date.now() - quietSince);
            if (left > 0) { schedule(left + 50); return; }
            busy = false;
            quietSince = 0;
            // Stopped by hand: no "replied".
            post({ busy: false, path: startPath, aborted: endedHere === 'aborted', via: 'quiet' });
          };
          const schedule = (delay = 300) => { if (!timer) timer = setTimeout(check, delay); };
          new MutationObserver(() => schedule()).observe(root(), {
            subtree: true, childList: true, attributes: true,
            attributeFilter: ['data-testid', 'aria-label', 'data-is-streaming', 'data-streaming-response-status',
                              'data-notchman-streams', 'data-notchman-stream-ends'],
          });
          setInterval(check, 1000);
          check();
        })();
        """
    }

    @MainActor static func install(in controller: WKUserContentController, service: ChatService,
                                   handler: WKScriptMessageHandler) {
        controller.addUserScript(WKUserScript(source: streamScript(for: service), injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(source: script(for: service), injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: .defaultClient))
        controller.add(handler, contentWorld: .defaultClient, name: handlerName)
    }
}

extension ChatService {
    /// `conversation(at:)`'s rule for a page path, as a JavaScript regex.
    var conversationPathPattern: String {
        switch self {
        case .chatgpt: #"/^(?:\/g\/[A-Za-z0-9-]+)?\/c\/[A-Za-z0-9-]{8,}\/?$/"#
        case .claude: #"/^\/chat\/[0-9a-fA-F-]{36}\/?$/"#
        case .muse: #"/\/(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{8,}\/?$/"#
        }
    }
}

/// What a chat page reported.
enum ReplyEvent: Equatable {
    /// The conversation on screen started or stopped writing.
    case state(ReplyState)
    /// A reply's stream ended in a conversation you've since left (`reason`: "complete" or "aborted").
    case elsewhere(path: String, reason: String)
}

struct ReplyState: Equatable {
    let busy: Bool
    let title: String
    /// The conversation's page path.
    var path = ""
    /// The reply was cancelled while you stayed (Stop).
    var aborted = false
    /// You left this conversation mid-reply.
    var left = false
    /// …and its stream was still open when you did.
    var streamOpen = false
    /// What showed it: "stream" or "page" (starting), "quiet" (done), "left".
    var via = ""
}

/// Forwards watcher messages without the content controller retaining the app (it holds handlers strongly).
final class ReplyMessageProxy: NSObject, WKScriptMessageHandler {
    private let onEvent: @MainActor (ReplyEvent) -> Void

    init(onEvent: @escaping @MainActor (ReplyEvent) -> Void) {
        self.onEvent = onEvent
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let event: ReplyEvent
        if body["kind"] as? String == "elsewhere" {
            guard let path = body["path"] as? String else { return }
            event = .elsewhere(path: path, reason: body["reason"] as? String ?? "complete")
        } else {
            guard let busy = body["busy"] as? Bool else { return }
            event = .state(ReplyState(busy: busy, title: body["title"] as? String ?? "", path: body["path"] as? String ?? "",
                                      aborted: body["aborted"] as? Bool ?? false, left: body["left"] as? Bool ?? false,
                                      streamOpen: body["streamOpen"] as? Bool ?? false, via: body["via"] as? String ?? ""))
        }
        MainActor.assumeIsolated { onEvent(event) }
    }
}
