import WebKit

/// Injected into each chat page: reports when the site starts and stops generating a reply, by watching
/// for its Stop button (ChatGPT, Claude and most chat UIs show one only while a reply is streaming).
/// Posts only `{busy: Bool, title: String}`; it never reads the conversation.
enum ReplyWatcher {
    static let handlerName = "notchmanReply"

    static let script = """
    (() => {
      if (window.__notchmanReplyWatcher) return;
      window.__notchmanReplyWatcher = true;
      const selectors = [
        '[data-testid="stop-button"]',        // ChatGPT
        'button[aria-label="Stop response"]', // Claude
        '[data-is-streaming="true"]',         // Claude
        'button[aria-label*="stop generating" i]',
        'button[aria-label^="stop" i]',
      ];
      let busy = false, pending = null;
      const check = () => {
        pending = null;
        const now = selectors.some(s => document.querySelector(s));
        if (now === busy) return;
        busy = now;
        window.webkit.messageHandlers.\(handlerName).postMessage({ busy, title: document.title || '' });
      };
      const schedule = () => { if (!pending) pending = setTimeout(check, 300); };
      new MutationObserver(schedule).observe(document.documentElement, {
        subtree: true, childList: true, attributes: true,
        attributeFilter: ['data-testid', 'aria-label', 'data-is-streaming'],
      });
      setInterval(check, 2000);
    })();
    """

    @MainActor static func install(in controller: WKUserContentController, handler: WKScriptMessageHandler) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: .defaultClient))
        controller.add(handler, contentWorld: .defaultClient, name: handlerName)
    }
}

/// Forwards watcher messages without the content controller retaining the app (it holds handlers strongly).
final class ReplyMessageProxy: NSObject, WKScriptMessageHandler {
    private let onMessage: @MainActor (Bool, String) -> Void

    init(onMessage: @escaping @MainActor (Bool, String) -> Void) {
        self.onMessage = onMessage
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let busy = body["busy"] as? Bool else { return }
        let title = body["title"] as? String ?? ""
        MainActor.assumeIsolated { onMessage(busy, title) }
    }
}
