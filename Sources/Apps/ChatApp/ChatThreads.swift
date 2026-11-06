import AppKit
import Foundation
import NotchKit
import WebKit

extension ChatService: Codable {}

/// One conversation on a chat site, for the Chats list: read from your account (the site's own chat list) or
/// remembered when you open it in the notch. Only its link, title, project and times — never its messages.
struct ChatThread: Codable, Identifiable, Hashable {
    let service: ChatService
    /// The site's id for the conversation (ChatGPT and Claude: a UUID).
    let conversationID: String
    var url: String
    var title: String
    var project: String?
    /// When the conversation last changed, as the site reports it.
    var updated: Date?
    /// When you last opened it in the notch.
    var opened: Date?

    var id: String { "\(service.rawValue):\(conversationID)" }

    /// What the list sorts and groups by: the later of the two.
    var lastActive: Date? {
        switch (updated, opened) {
        case let (a?, b?): max(a, b)
        case let (a, b): a ?? b
        }
    }

    var displayTitle: String { title.isEmpty ? "Untitled chat" : title }
}

extension ChatService {
    /// The conversation a page on this site is, if it is one: ChatGPT `/c/<id>` (also inside a project or GPT,
    /// `/g/<id>/c/<id>`), Claude `/chat/<uuid>`, and on Muse any page whose last path part looks like an id.
    func conversation(at url: URL) -> (id: String, url: URL)? {
        guard page(url.absoluteString) != nil else { return nil }
        let path = url.path()
        switch self {
        case .chatgpt:
            guard let match = path.firstMatch(of: /^(?:\/g\/[A-Za-z0-9-]+)?\/c\/([A-Za-z0-9-]{8,})\/?$/) else { return nil }
            return (String(match.1), url)
        case .claude:
            guard let match = path.firstMatch(of: /^\/chat\/([0-9a-fA-F-]{36})\/?$/) else { return nil }
            return (String(match.1).lowercased(), url)
        case .muse:
            let parts = path.split(separator: "/").map(String.init)
            guard let last = parts.last, !Self.museNonChatPaths.contains(parts.first?.lowercased() ?? ""),
                  last.wholeMatch(of: /[A-Za-z0-9_-]{8,}/) != nil,
                  last.contains(where: \.isNumber), last.contains(where: \.isLetter) else { return nil }
            return (last, url)
        }
    }

    /// Muse pages that carry ids but aren't conversations.
    private static let museNonChatPaths: Set<String> = ["settings", "account", "billing", "login", "signup", "auth", "help"]

    /// The page's tab title as a chat title: without the site's name, and empty when it's just the site's name.
    static func chatTitle(fromPageTitle raw: String) -> String {
        let cleaned = cleanName(raw)
            .replacingOccurrences(of: #"\s*[-|·–]\s*(ChatGPT|Claude|muse\.ai|Muse)\s*$"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        let generic = ["", "chatgpt", "claude", "muse", "muse.ai", "new chat", "new conversation"]
        return generic.contains(cleaned.lowercased()) ? "" : cleaned
    }

    /// Runs on the signed-in site: the account's conversations from the site's own list (what its sidebar
    /// shows), as `{api: [{id, title, updated (ms), project}], links: [{href, name}]}`. The links are the
    /// page's, for chats the list leaves out and for sites without one (Muse).
    ///
    /// Arguments (both optional): `full` reads everything — every page of the list, each ChatGPT project's chats
    /// (`projects`: extra `g-p-…` ids to look in) and, without a list, the sidebar scrolled to its end — instead
    /// of just the newest 100.
    var chatListScript: String {
        let api: String
        switch self {
        case .chatgpt:
            api = """
            const session = await (await fetch('/api/auth/session', { credentials: 'include' })).json();
            if (!session || !session.accessToken) return null;
            const get = async url => {
              const response = await fetch(url,
                { credentials: 'include', headers: { Authorization: 'Bearer ' + session.accessToken } });
              return response.ok ? response.json() : null;
            };
            const row = (c, project) => ({
              id: c.id, title: c.title || '', updated: ms(c.update_time || c.create_time), project: project || '',
            });
            const all = [];
            for (let offset = 0; offset < 20000; offset += 100) {
              const body = await get(`/backend-api/conversations?offset=${offset}&limit=100&order=updated`);
              if (!body) { if (offset === 0) return null; partial = true; break; }
              const items = body.items || [];
              for (const c of items) all.push(row(c, c.gizmo_id));
              if (!isFull || items.length < 100 || (body.total && offset + 100 >= body.total)) break;
            }
            if (isFull) {
              // Project chats aren't in the main list: read each project's own.
              const ids = new Set([...extraProjects, ...all.map(c => c.project)].filter(p => /^g-p-/.test(p)));
              for (const a of document.querySelectorAll('a[href*="/g/g-p-"]')) {
                const match = (a.getAttribute('href') || '').match(/\\/g\\/(g-p-[A-Za-z0-9]+)/);
                if (match) ids.add(match[1]);
              }
              for (const project of ids) {
                let cursor = 0;
                for (let page = 0; page < 200; page++) {
                  const body = await get(`/backend-api/gizmos/${project}/conversations?cursor=${cursor}`);
                  if (!body) partial = true;
                  const items = (body && body.items) || [];
                  for (const c of items) all.push(row(c, project));
                  if (!items.length || body.cursor == null || body.cursor === cursor) break;
                  cursor = body.cursor;
                }
              }
            }
            return all;
            """
        case .claude:
            api = """
            const orgs = await (await fetch('/api/organizations', { credentials: 'include' })).json();
            if (!Array.isArray(orgs)) return null;
            const all = [], seen = new Set();
            const add = chats => {
              let added = 0;
              for (const c of chats) {
                if (!c || seen.has(c.uuid)) continue;
                seen.add(c.uuid);
                added++;
                all.push({
                  id: c.uuid, title: c.name || '', updated: ms(c.updated_at || c.created_at),
                  project: (c.project && c.project.name) || '',
                });
              }
              return added;
            };
            const get = async url => {
              const response = await fetch(url, { credentials: 'include' });
              if (!response.ok) return null;
              const body = await response.json();
              return Array.isArray(body) ? body : null;
            };
            let any = false;
            for (const org of orgs) {
              const base = `/api/organizations/${org.uuid}/chat_conversations`;
              for (let offset = 0; offset < 20000; offset += 100) {
                const chats = await get(`${base}?limit=100&offset=${offset}`);
                if (!chats) { if (offset > 0) partial = true; break; }
                any = true;
                const added = add(chats);
                if (!isFull || chats.length < 100) break;
                // The same page again: no paging here, so ask for the whole list at once.
                if (added === 0) {
                  const whole = await get(base);
                  if (whole) add(whole); else partial = true;
                  break;
                }
              }
            }
            return any ? all : null;
            """
        case .muse:
            api = "return null;"
        }
        return """
        const isFull = typeof full !== 'undefined' && !!full;
        const extraProjects = typeof projects !== 'undefined' && Array.isArray(projects) ? projects : [];
        const ms = v => typeof v === 'number' ? (v < 1e12 ? v * 1000 : v) : (Date.parse(v || '') || 0);
        // Set when part of a full read failed, so nothing is taken as deleted.
        let partial = false;
        let api = null;
        try { api = await (async () => { \(api) })(); } catch (e) { api = null; }
        if (isFull && api === null) {
          // No list to read: scroll the sidebar to its end so it loads every chat link.
          const scrollers = [...document.querySelectorAll('nav, aside, nav *, aside *')].filter(el =>
            /(auto|scroll)/.test(getComputedStyle(el).overflowY) && el.scrollHeight > el.clientHeight + 20);
          let count = -1, stable = 0;
          for (let round = 0; round < 80 && scrollers.length && stable < 3; round++) {
            scrollers.forEach(el => { el.scrollTop = el.scrollHeight; });
            await new Promise(resolve => setTimeout(resolve, 600));
            const now = document.querySelectorAll('a[href]').length;
            stable = now === count ? stable + 1 : 0;
            count = now;
          }
        }
        \(Self.linkScript.replacingOccurrences(of: "return [", with: "const links = ["))
        return { api, links, complete: isFull && api !== null && !partial };
        """
    }

    /// Turns what `chatListScript` returned into conversations, newest first as the site listed them.
    /// `projectNames` names ChatGPT project ids (`g-p-…`) from the saved projects.
    func threads(fromList result: [String: Any], projectNames: [String: String] = [:]) -> [ChatThread] {
        var found: [ChatThread] = []
        var seen = Set<String>()
        for item in result["api"] as? [[String: Any]] ?? [] {
            guard let id = item["id"] as? String, !id.isEmpty, seen.insert(id.lowercased()).inserted else { continue }
            let url = switch self {
            case .chatgpt: "https://chatgpt.com/c/\(id)"
            case .claude: "https://claude.ai/chat/\(id)"
            case .muse: id
            }
            let millis = (item["updated"] as? NSNumber)?.doubleValue ?? 0
            let project = (item["project"] as? String).flatMap { projectName($0, names: projectNames) }
            found.append(ChatThread(service: self, conversationID: self == .claude ? id.lowercased() : id, url: url,
                                    title: Self.cleanName(item["title"] as? String ?? ""), project: project,
                                    updated: millis > 0 ? Date(timeIntervalSince1970: millis / 1000) : nil))
        }
        let links = (result["links"] as? [[String: Any]] ?? []).map { $0.compactMapValues { $0 as? String } }
        for link in links {
            guard let href = link["href"], let absolute = URL(string: href, relativeTo: home)?.absoluteURL,
                  let conversation = conversation(at: absolute),
                  seen.insert(conversation.id.lowercased()).inserted else { continue }
            let title = Self.cleanName((link["name"] ?? "").split(separator: "\n").first.map(String.init) ?? "")
            let projectID = absolute.path().firstMatch(of: /^\/g\/(g-p-[A-Za-z0-9-]+)\//).map { String($0.1) }
            found.append(ChatThread(service: self, conversationID: conversation.id,
                                    url: conversation.url.absoluteString, title: title,
                                    project: projectID.flatMap { projectName($0, names: projectNames) }))
        }
        return found
    }

    /// A project's name from what the site gave (Claude: the name; ChatGPT: a `g-p-…` id, named from your saved
    /// projects or its slug). Custom GPTs (`g-…` without `p`) aren't projects.
    private func projectName(_ raw: String, names: [String: String]) -> String? {
        guard !raw.isEmpty else { return nil }
        guard self == .chatgpt else { return raw }
        guard raw.hasPrefix("g-p-") else { return nil }
        if let name = names.first(where: { raw.hasPrefix($0.key) || $0.key.hasPrefix(raw) })?.value { return name }
        let slug = raw.split(separator: "-").dropFirst(3).joined(separator: " ")
        return slug.isEmpty ? "Project" : slug
    }
}

enum ChatThreads {
    /// Adds what was just read (or opened) to the list: new conversations are added, known ones take the newer
    /// title, project and times. Nothing is dropped (a conversation can be removed by hand).
    static func merge(_ existing: [ChatThread], _ fresh: [ChatThread]) -> [ChatThread] {
        var result = existing
        var index = Dictionary(result.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        for thread in fresh {
            guard let at = index[thread.id] else {
                index[thread.id] = result.count
                result.append(thread)
                continue
            }
            var known = result[at]
            if !thread.title.isEmpty { known.title = thread.title }
            if let project = thread.project { known.project = project }
            if let updated = thread.updated { known.updated = max(updated, known.updated ?? .distantPast) }
            if let opened = thread.opened { known.opened = max(opened, known.opened ?? .distantPast) }
            // A project chat's own link beats the short one.
            if thread.url.count > known.url.count || known.url.isEmpty { known.url = thread.url }
            result[at] = known
        }
        return result
    }

    /// After reading a service's whole list: merges it in and drops that service's conversations it no longer
    /// has (deleted on the site), except pinned ones.
    static func replacing(_ existing: [ChatThread], with complete: [ChatThread], for service: ChatService,
                          pinned: Set<String>) -> [ChatThread] {
        let listed = Set(complete.map(\.id))
        return merge(existing, complete).filter { $0.service != service || listed.contains($0.id) || pinned.contains($0.id) }
    }

    /// Newest first; conversations without a time keep the order the site listed them in, after the rest.
    static func sorted(_ threads: [ChatThread]) -> [ChatThread] {
        threads.enumerated().sorted { a, b in
            switch (a.element.lastActive, b.element.lastActive) {
            case let (x?, y?): x == y ? a.offset < b.offset : x > y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Keeps the list from growing forever: the newest `perService` of each service, plus every pinned one.
    static func trimmed(_ threads: [ChatThread], pinned: Set<String>, perService: Int = 3000) -> [ChatThread] {
        var counts: [ChatService: Int] = [:]
        return sorted(threads).filter { thread in
            counts[thread.service, default: 0] += 1
            return pinned.contains(thread.id) || counts[thread.service]! <= perService
        }
    }

    /// Matches every word of the search in the title, project or service name.
    static func matches(_ thread: ChatThread, query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = "\(thread.title) \(thread.project ?? "") \(thread.service.name)".lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    enum Section: String, CaseIterable, Identifiable {
        case pinned = "Pinned", today = "Today", yesterday = "Yesterday", week = "Previous 7 Days",
             month = "Previous 30 Days", older = "Older"
        var id: String { rawValue }
    }

    static func section(of thread: ChatThread, pinned: Set<String>, now: Date = Date(),
                        calendar: Calendar = .current) -> Section {
        if pinned.contains(thread.id) { return .pinned }
        guard let date = thread.lastActive else { return .older }
        let start = calendar.startOfDay(for: now)
        if date >= start { return .today }
        if date >= calendar.date(byAdding: .day, value: -1, to: start)! { return .yesterday }
        if date >= calendar.date(byAdding: .day, value: -7, to: start)! { return .week }
        if date >= calendar.date(byAdding: .day, value: -30, to: start)! { return .month }
        return .older
    }

    /// The list's sections in order, each newest first, leaving out empty ones.
    static func grouped(_ threads: [ChatThread], pinned: Set<String>,
                        now: Date = Date()) -> [(section: Section, threads: [ChatThread])] {
        let bySection = Dictionary(grouping: sorted(threads)) { section(of: $0, pinned: pinned, now: now) }
        return Section.allCases.compactMap { section in bySection[section].map { (section, $0) } }
    }
}

/// Reads a service's chat list from a hidden, desktop-width copy of the site (sharing your sign-in), like
/// `ProjectScraper`: the site's own list when it has one, plus the chats linked in its sidebar.
@MainActor
final class ChatListScraper: NSObject, WKNavigationDelegate {
    private let service: ChatService
    private let userAgent: String?
    private let page: URL
    private let projectNames: [String: String]
    private var webView: WKWebView?
    private var window: NSWindow?

    init(service: ChatService, userAgent: String?, projectNames: [String: String] = [:], page: URL? = nil) {
        self.service = service
        self.userAgent = userAgent
        self.projectNames = projectNames
        self.page = page ?? service.home
    }

    struct Result {
        let threads: [ChatThread]
        /// The site's whole list was read (a full read that got the list), so missing chats were deleted.
        var complete = false
    }

    /// The newest chats; with `full`, every chat (see `chatListScript`) — slower, for a full sync.
    func run(full: Bool = false, timeout: TimeInterval = 15) async throws -> Result {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // same cookies as the notch's page
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), configuration: config)
        view.customUserAgent = userAgent
        view.navigationDelegate = self
        // Offscreen window so the sidebar lays out at desktop width (and the page isn't throttled as hidden).
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
        var best: [ChatThread] = []
        var rounds = 0, stableRounds = 0
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
            if view.isLoading { continue }
            if let host = view.url?.host(), let expected = page.host(),
               !host.hasSuffix(expected) || view.url?.path().contains("login") == true {
                throw ProjectScraper.ScrapeError.notSignedIn(service.name)
            }
            rounds += 1
            if full {
                // Give the site's app a moment to start (and its sidebar to show), then read it all once.
                guard rounds >= 4 else { continue }
                let raw = try? await view.callAsyncJavaScript(
                    service.chatListScript, arguments: ["full": true, "projects": Array(projectNames.keys)], in: nil,
                    contentWorld: .defaultClient)
                let result = raw as? [String: Any] ?? [:]
                return Result(threads: service.threads(fromList: result, projectNames: projectNames),
                              complete: result["complete"] as? Bool ?? false)
            }
            let raw = try? await view.callAsyncJavaScript(service.chatListScript, arguments: [:], in: nil,
                                                          contentWorld: .defaultClient)
            let result = raw as? [String: Any] ?? [:]
            let found = service.threads(fromList: result, projectNames: projectNames)
            if found.count > best.count {
                best = found
                stableRounds = 0
            } else {
                stableRounds += 1
            }
            // The site's own list comes back whole; give the sidebar a moment for the chats it leaves out.
            let fromList = (result["api"] as? [Any])?.isEmpty == false
            if fromList && rounds >= 3 { break }
            if !best.isEmpty && stableRounds >= 4 { break }
        }
        return Result(threads: best)
    }

    private func close() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        window?.close()
        webView = nil
        window = nil
    }
}
