import WebKit

/// Where you were in a conversation.
struct ScrollSpot: Equatable {
    let top: Double
    /// You were following the newest message; restore to the bottom even if new messages arrived.
    let atBottom: Bool
}

/// Remembers each conversation's scroll position so reopening the notch puts you back where you were.
/// A page script reports positions as you scroll (just numbers and the page path, never content).
enum ScrollMemory {
    static let handlerName = "notchmanScroll"

    /// Finds the conversation's scroll area: the scrollable ancestor of the last message, else the largest
    /// scrollable area in <main>, else null (the page itself scrolls).
    static let findScroller = """
    const notchmanScroller = () => {
      const scrollable = el => {
        const style = getComputedStyle(el);
        return /(auto|scroll)/.test(style.overflowY) && el.scrollHeight > el.clientHeight + 20;
      };
      const messages = document.querySelectorAll(
        '[data-message-author-role], [data-testid^="conversation-turn"], [data-test-render-count]');
      let target = messages.length ? messages[messages.length - 1].parentElement : null;
      while (target && !scrollable(target)) target = target.parentElement;
      if (!target) {
        target = [...document.querySelectorAll('main *, main')].filter(scrollable)
          .sort((a, b) => b.clientHeight - a.clientHeight)[0] || null;
      }
      return target;
    };
    """

    /// Injected into chat pages: reports {path, top, atBottom} a moment after scrolling stops.
    static let reporterScript = """
    (() => {
      if (window.__notchmanScrollReporter) return;
      window.__notchmanScrollReporter = true;
      \(findScroller)
      let pending = null;
      const report = () => {
        pending = null;
        const el = notchmanScroller();
        const top = el ? el.scrollTop : window.scrollY;
        const height = el ? el.scrollHeight : document.documentElement.scrollHeight;
        const visible = el ? el.clientHeight : window.innerHeight;
        window.webkit.messageHandlers.\(handlerName).postMessage({
          path: location.pathname, top, atBottom: top + visible >= height - 40,
        });
      };
      document.addEventListener('scroll', () => {
        if (pending) clearTimeout(pending);
        pending = setTimeout(report, 250);
      }, { capture: true, passive: true });
    })();
    """

    /// Restores a spot (`top`, `atBottom` passed as arguments). Returns where it scrolled.
    static let restoreScript = """
    \(findScroller)
    const el = notchmanScroller();
    if (el) {
      el.scrollTop = atBottom ? el.scrollHeight : top;
      return 'element';
    }
    window.scrollTo(0, atBottom ? document.documentElement.scrollHeight : top);
    return 'page';
    """

    @MainActor static func install(in controller: WKUserContentController, handler: WKScriptMessageHandler) {
        controller.addUserScript(WKUserScript(source: reporterScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: .defaultClient))
        controller.add(handler, contentWorld: .defaultClient, name: handlerName)
    }
}

/// Forwards scroll reports without the content controller retaining the app.
final class ScrollMessageProxy: NSObject, WKScriptMessageHandler {
    private let onSpot: @MainActor (String, ScrollSpot) -> Void

    init(onSpot: @escaping @MainActor (String, ScrollSpot) -> Void) {
        self.onSpot = onSpot
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let path = body["path"] as? String,
              let top = (body["top"] as? NSNumber)?.doubleValue else { return }
        let spot = ScrollSpot(top: top, atBottom: body["atBottom"] as? Bool ?? false)
        MainActor.assumeIsolated { onSpot(path, spot) }
    }
}
