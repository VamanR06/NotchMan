import AppKit
import NotchKit
import WebKit

/// Reads a service's project list from a hidden, desktop-width copy of the site (sharing your sign-in).
///
/// The notch's own page is too narrow: ChatGPT collapses its sidebar there, so no project links are on the page.
/// The sidebar also fills in after the page loads, so this keeps looking for a while.
@MainActor
final class ProjectScraper: NSObject, WKNavigationDelegate {
    struct Result {
        let projects: [AskProject]
        /// How many links were on the page (for explaining an empty result).
        let linksSeen: Int
        /// A few project-looking link paths, logged when nothing matched (to spot a changed link format).
        var candidatePaths: [String] = []
    }

    enum ScrapeError: LocalizedError {
        case notSignedIn(String)
        var errorDescription: String? {
            switch self {
            case .notSignedIn(let service): "Sign in to \(service) in the notch first, then try again."
            }
        }
    }

    private let service: ChatService
    private let userAgent: String?
    private let page: URL
    private var webView: WKWebView?
    private var window: NSWindow?

    /// `page` defaults to where the service lists its projects (tests point it elsewhere).
    init(service: ChatService, userAgent: String?, page: URL? = nil) {
        self.service = service
        self.userAgent = userAgent
        self.page = page ?? Self.listPage(for: service)
    }

    /// Where the full project list is visible.
    static func listPage(for service: ChatService) -> URL {
        switch service {
        case .claude: URL(string: "https://claude.ai/projects")!
        default: service.home
        }
    }

    func run(timeout: TimeInterval = 15) async throws -> Result {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // same cookies as the notch's page
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), configuration: config)
        view.customUserAgent = userAgent
        view.navigationDelegate = self
        // Offscreen window so the page lays out at desktop width (and doesn't get throttled as hidden).
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 1440, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        self.webView = view
        self.window = window
        defer { close() }

        view.load(URLRequest(url: page))
        let deadline = Date().addingTimeInterval(timeout)
        var best = Result(projects: [], linksSeen: 0)
        var stableRounds = 0
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
            if view.isLoading { continue }
            // Sent off to a sign-in page (another host, or a login path).
            if let host = view.url?.host(), let expected = page.host(),
               !host.hasSuffix(expected) || view.url?.path().contains("login") == true {
                throw ScrapeError.notSignedIn(service.name)
            }
            let raw = try? await view.callAsyncJavaScript(ChatService.linkScript, arguments: [:], in: nil,
                                                          contentWorld: .defaultClient)
            let links = (raw as? [[String: Any]] ?? []).map { $0.compactMapValues { $0 as? String } }
            let found = service.projects(fromLinks: links)
            let candidates = links.compactMap { $0["href"] }
                .filter { $0.contains("project") || $0.contains("/g/") }
                .prefix(10)
                .map { URL(string: $0, relativeTo: page)?.path() ?? $0 }
            if found.count > best.projects.count {
                best = Result(projects: found, linksSeen: links.count, candidatePaths: Array(candidates))
                stableRounds = 0
            } else {
                best = Result(projects: best.projects, linksSeen: max(best.linksSeen, links.count),
                              candidatePaths: best.candidatePaths.isEmpty ? Array(candidates) : best.candidatePaths)
                stableRounds += 1
            }
            // Once projects have shown up and the list stopped growing for ~2s, we're done.
            if !best.projects.isEmpty && stableRounds >= 4 { break }
        }
        return Result(projects: await named(best.projects, using: view), linksSeen: best.linksSeen,
                      candidatePaths: best.candidatePaths)
    }

    /// Looks up names for projects found only through their chats by opening each project's page.
    private func named(_ projects: [AskProject], using view: WKWebView) async -> [AskProject] {
        var result = projects
        for index in result.indices where result[index].name.isEmpty {
            guard let url = URL(string: result[index].url) else { continue }
            view.load(URLRequest(url: url))
            var name = ""
            for _ in 0..<16 {  // up to ~8s
                try? await Task.sleep(for: .milliseconds(500))
                if view.isLoading { continue }
                let raw = try? await view.callAsyncJavaScript(ChatService.projectNameScript, arguments: [:], in: nil,
                                                              contentWorld: .defaultClient)
                name = ChatService.cleanName(raw as? String ?? "")
                if !name.isEmpty { break }
            }
            let id = url.pathComponents.dropFirst(2).first.map { String($0.suffix(6)) } ?? ""
            result[index].name = name.isEmpty ? "Project \(id)" : name
        }
        return result
    }

    private func close() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        window?.close()
        webView = nil
        window = nil
    }
}
