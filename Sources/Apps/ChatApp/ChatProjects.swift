import Foundation
import NotchKit

extension ChatService {
    /// ChatGPT and Claude have projects; Muse doesn't.
    var supportsProjects: Bool { self != .muse }

    /// Chat threads (ChatGPT, Claude) open at their newest message; Muse isn't a chat thread.
    var scrollsToLatest: Bool { self != .muse }

    /// Scrolls the conversation to its newest message: the scrollable ancestor of the last message if there is
    /// one, else the largest scrollable area, else the page. Does nothing on pages that don't scroll.
    static let scrollToLatestScript = """
    (() => {
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
      if (target) { target.scrollTop = target.scrollHeight; return 'element'; }
      window.scrollTo(0, document.documentElement.scrollHeight);
      return 'page';
    })();
    """

    /// Turns the page's links (`href` + visible text) into this service's projects, ignoring everything else
    /// (including chats *inside* a project, which link to the same project prefix).
    func projects(fromLinks links: [[String: String]]) -> [AskProject] {
        var found: [AskProject] = []
        for link in links {
            guard let href = link["href"], let project = project(fromHref: href, text: link["name"] ?? "") else { continue }
            if let index = found.firstIndex(where: { $0.url == project.url }) {
                if found[index].name.isEmpty { found[index].name = project.name }
            } else {
                found.append(project)
            }
        }
        return found.filter { !$0.name.isEmpty }
    }

    private func project(fromHref href: String, text: String) -> AskProject? {
        guard let site = home.host() else { return nil }
        let path = URL(string: href, relativeTo: home)?.path() ?? href
        let name = text.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        switch self {
        case .chatgpt:
            // Project home: /g/g-p-<hex>-<slug> or /g/g-p-<hex>-<slug>/project (not …/c/<chat>).
            guard let match = path.firstMatch(of: /^\/g\/(g-p-[A-Za-z0-9-]+)(\/project)?\/?$/) else { return nil }
            let id = String(match.1)
            return AskProject(name: name.isEmpty ? Self.slugName(id) : name, url: "https://\(site)/g/\(id)/project")
        case .claude:
            guard let match = path.firstMatch(of: /^\/project\/([0-9a-fA-F-]{36})\/?$/) else { return nil }
            return AskProject(name: name, url: "https://\(site)/project/\(match.1)")
        case .muse:
            return nil
        }
    }

    /// "g-p-67c8ab12cd-job-search" → "job search".
    private static func slugName(_ id: String) -> String {
        let parts = id.split(separator: "-").dropFirst(3)
        return parts.joined(separator: " ")
    }

    /// Lists every link on the page; filtering happens in Swift (`projects(fromLinks:)`).
    static let linkScript = """
    return [...document.querySelectorAll('a[href]')].slice(0, 3000).map(a => ({
      href: a.getAttribute('href') || '',
      name: (a.innerText || a.getAttribute('aria-label') || '').trim(),
    }));
    """
}
