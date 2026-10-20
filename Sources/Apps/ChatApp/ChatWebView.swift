import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The chat services, each loaded as its real website so usage is exactly like using the site.
enum ChatService: String, CaseIterable, Identifiable {
    case chatgpt, claude

    var id: String { rawValue }

    var name: String {
        switch self {
        case .chatgpt: "ChatGPT"
        case .claude: "Claude"
        }
    }

    var home: URL {
        switch self {
        case .chatgpt: URL(string: "https://chatgpt.com/")!
        case .claude: URL(string: "https://claude.ai/new")!
        }
    }
}

/// WKWebView that takes keyboard focus when clicked, even inside the non-activating notch panel.
final class NotchWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }
}

/// Navigation/UI delegate: keeps the chat site and its sign-in flows in the notch,
/// sends every other link to the default browser, and handles file uploads.
@MainActor
final class ChatWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// Hosts that stay inside the notch: the chat sites plus the sign-in providers they redirect through.
    private static let inAppHosts = [
        "chatgpt.com", "openai.com", "claude.ai", "anthropic.com",
        "accounts.google.com", "appleid.apple.com", "login.microsoftonline.com", "login.live.com",
        "challenges.cloudflare.com",
    ]

    static func staysInApp(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return true }
        return inAppHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        if url?.scheme == "about" || url?.scheme == "blob" || url?.scheme == "data" { return .allow }
        // Only user-clicked links leave the app; redirects during sign-in must stay.
        if navigationAction.navigationType == .linkActivated, !Self.staysInApp(url), let url {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        return .allow
    }

    /// `window.open` (sign-in popups, "open in new tab"): load sign-in in place, open others in the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if Self.staysInApp(url) {
                webView.load(navigationAction.request)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
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

/// Hosts a long-lived web view; the view itself survives the notch collapsing.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
