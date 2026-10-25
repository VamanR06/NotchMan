import AppKit
import NotchKit
import os
import SwiftUI
import WebKit

/// The chat services, each loaded as its real website so usage is exactly like using the site.
enum ChatService: String, CaseIterable, Identifiable {
    case chatgpt, claude, muse

    var id: String { rawValue }

    var name: String {
        switch self {
        case .chatgpt: "ChatGPT"
        case .claude: "Claude"
        case .muse: "Muse"
        }
    }

    /// `string` if it's an https page on this service's own site (e.g. a ChatGPT project), else nil.
    func page(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string.trimmingCharacters(in: .whitespaces)),
              url.scheme == "https", let host = url.host()?.lowercased(),
              let site = home.host()?.lowercased() else { return nil }
        return host == site || host.hasSuffix("." + site) ? url : nil
    }

    /// Compact label for the collapsed notch.
    var shortName: String {
        switch self {
        case .chatgpt: "GPT"
        case .claude: "Claude"
        case .muse: "Muse"
        }
    }

    var home: URL {
        switch self {
        case .chatgpt: URL(string: "https://chatgpt.com/")!
        case .claude: URL(string: "https://claude.ai/new")!
        case .muse: URL(string: "https://muse.ai/")!
        }
    }
}

/// WKWebView that takes keyboard focus when clicked, even inside the non-activating notch panel.
final class NotchWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Pages open pop-ups (password AutoFill and its unlock prompt, pickers) that can only take the keyboard if
    // NotchMan is active — so any click into the page, or the page gaining focus, activates it.
    override func mouseDown(with event: NSEvent) {
        focusForTyping()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        focusForTyping()
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        focusForTyping()
        super.otherMouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { NotchFocus.activateForTyping() }
        return accepted
    }

    private func focusForTyping() {
        NotchFocus.activateForTyping()
        window?.makeKey()
    }
}

/// Navigation/UI delegate: keeps the chat site and its sign-in flows in the notch,
/// sends every other link to the default browser, and handles file uploads.
@MainActor
final class ChatWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    var logger = Logger(subsystem: "com.notchman", category: "chat")
    /// Called when a page finishes loading (used to type in a pending prompt).
    var onFinish: ((WKWebView) -> Void)?
    /// Sign-in popups, shown in their own windows so `window.opener` keeps working.
    private var popups: [ObjectIdentifier: NSWindow] = [:]

    /// Hosts that stay inside the notch: the chat sites plus the sign-in providers they redirect through.
    private static let inAppHosts = [
        "chatgpt.com", "openai.com", "claude.ai", "anthropic.com",
        "muse.ai",
        "accounts.google.com", "appleid.apple.com", "login.microsoftonline.com", "login.live.com",
        "challenges.cloudflare.com",
    ]

    static func staysInApp(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return true }
        return inAppHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        // Host and path only: query strings can carry sign-in tokens.
        let place = "\(url?.scheme == "https" ? "" : (url?.scheme ?? "-") + ":")\(url?.host() ?? "")\(url?.path() ?? "")"
        if navigationAction.targetFrame?.isMainFrame == true {
            logger.notice("Navigate \(place, privacy: .public)")
        } else {
            // In-page frames (embedded viewers, previews) are where site features break most quietly.
            logger.notice("Frame \(place, privacy: .public) (\(String(describing: navigationAction.navigationType.rawValue), privacy: .public))")
        }
        if url?.scheme == "about" || url?.scheme == "blob" || url?.scheme == "data" { return .allow }
        // Only user-clicked links leave the app; redirects during sign-in must stay.
        if navigationAction.navigationType == .linkActivated, !Self.staysInApp(url), let url {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        return .allow
    }

    /// What came back for each load: logged when it isn't an ordinary page, or when WebKit can't show it (a
    /// PDF in a frame, say), since those fail silently inside the page.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let response = navigationResponse.response
        let mime = response.mimeType ?? "-"
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        if mime != "text/html" || !navigationResponse.canShowMIMEType || status >= 400 || !navigationResponse.isForMainFrame {
            let place = "\(response.url?.host() ?? "")\(response.url?.path() ?? "")"
            var line = "Response \(place): \(status) \(mime)"
            if !navigationResponse.isForMainFrame { line += " in frame" }
            if !navigationResponse.canShowMIMEType { line += " (WebKit can't show this)" }
            if let disposition { line += " disposition: \(disposition.prefix(60))" }
            logger.notice("\(line, privacy: .public)")
        }
        return .allow
    }

    /// `window.open`: sign-in popups get a real window (with the opener link intact, so the popup can hand
    /// the session back to the page); anything else opens in the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        let blank = url == nil || url?.absoluteString.isEmpty == true || url?.scheme == "about"
        if !blank, !Self.staysInApp(url), let url {
            NSWorkspace.shared.open(url)
            return nil
        }
        logger.notice("Popup \(url?.host() ?? "blank", privacy: .public)")
        let popup = NotchWebView(frame: CGRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
        popup.customUserAgent = webView.customUserAgent
        popup.navigationDelegate = self
        popup.uiDelegate = self

        let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Sign in"
        window.contentView = popup
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        popups[ObjectIdentifier(popup)] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    /// The popup called `window.close()` (e.g. sign-in finished).
    func webViewDidClose(_ webView: WKWebView) {
        popups.removeValue(forKey: ObjectIdentifier(webView))?.close()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        logger.error("Load failed: \(error.localizedDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        logger.error("Navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    /// A crashed or killed page leaves a blank view; bring it back.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logger.error("Web content process terminated; reloading")
        webView.reload()
    }

    /// File attachments.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        NSApp.activate()
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

/// Tells the Chat app when a popped-out chat window closes so the chat returns to the notch.
final class WindowCloseObserver: NSObject, NSWindowDelegate {
    private let onClose: @MainActor () -> Void

    init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { onClose() }
    }
}
