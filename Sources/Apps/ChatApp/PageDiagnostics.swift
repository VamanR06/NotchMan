import WebKit
import os

/// Injected into chat pages (every frame): reports what goes wrong inside the page — failed requests (status
/// 400+ or no response), script errors, rejected promises, and console errors — to NotchMan's log, so problems
/// like a file preview that won't load can be diagnosed. Addresses are reported as host and path only (query
/// strings can carry tokens), messages are cut short, and the conversation itself is never read.
/// Read with: log show --predicate 'subsystem == "com.notchman" AND category == "chat"' --last 1h
enum PageDiagnostics {
    static let handlerName = "notchmanDiagnostics"

    static let script = """
    (() => {
      if (window.__notchmanDiagnostics) return;
      window.__notchmanDiagnostics = true;
      const post = (kind, detail) => {
        try { window.webkit.messageHandlers.\(handlerName).postMessage({ kind, detail: String(detail).slice(0, 400), frame: location.host + location.pathname }); } catch (e) {}
      };
      const where = (u) => { try { const x = new URL(u, location.href); return x.protocol === 'blob:' || x.protocol === 'data:' ? x.protocol : x.host + x.pathname; } catch (e) { return String(u).slice(0, 120); } };
      const origFetch = window.fetch;
      window.fetch = function (input, init) {
        const url = typeof input === 'string' ? input : (input && input.url) || '';
        return origFetch.apply(this, arguments).then((r) => {
          if (r.status >= 400) post('fetch', r.status + ' ' + where(url));
          return r;
        }, (e) => { post('fetch', 'failed ' + where(url) + ': ' + (e && e.message || e)); throw e; });
      };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.addEventListener('loadend', () => { if (this.status === 0 || this.status >= 400) post('xhr', this.status + ' ' + where(url)); });
        return open.apply(this, arguments);
      };
      window.addEventListener('error', (e) => {
        if (e.target && e.target !== window && (e.target.src || e.target.href)) post('resource', 'failed ' + (e.target.tagName || '') + ' ' + where(e.target.src || e.target.href));
        else post('error', (e.message || 'error') + ' at ' + where(e.filename || '') + ':' + (e.lineno || 0));
      }, true);
      window.addEventListener('unhandledrejection', (e) => post('rejection', e.reason && (e.reason.stack || e.reason.message) || e.reason));
      const consoleError = console.error;
      console.error = function () {
        post('console', Array.from(arguments).map((a) => a && a.message ? a.message : typeof a === 'string' ? a : '').join(' '));
        return consoleError.apply(this, arguments);
      };
      document.addEventListener('securitypolicyviolation', (e) => post('csp', e.violatedDirective + ' blocked ' + where(e.blockedURI)));
    })();
    """

    @MainActor static func install(in controller: WKUserContentController, handler: WKScriptMessageHandler) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: .page))
        controller.add(handler, contentWorld: .page, name: handlerName)
    }
}

/// Writes page diagnostics to the log (without the content controller retaining the app).
final class DiagnosticsMessageProxy: NSObject, WKScriptMessageHandler {
    private let logger: Logger
    private var recent: [String: Date] = [:]

    init(logger: Logger) {
        self.logger = logger
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String,
              let detail = body["detail"] as? String else { return }
        let frame = body["frame"] as? String ?? ""
        let line = "[page \(kind)] \(detail) (in \(frame))"
        // The same error repeating in a loop is logged once a minute.
        let now = Date()
        if let last = recent[line], now.timeIntervalSince(last) < 60 { return }
        recent[line] = now
        if recent.count > 500 { recent.removeAll() }
        logger.error("\(line, privacy: .public)")
    }
}
