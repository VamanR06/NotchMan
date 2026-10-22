import Foundation
import NotchKit

extension ChatService {
    /// ChatGPT and Claude have projects; Muse doesn't.
    var supportsProjects: Bool { self != .muse }

    /// Chat threads (ChatGPT, Claude) open at their newest message; Muse isn't a chat thread.
    var scrollsToLatest: Bool { self != .muse }


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
        // Projects seen only through their chats have no name yet (`ProjectScraper` looks it up).
        return found
    }

    private func project(fromHref href: String, text: String) -> AskProject? {
        guard let site = home.host() else { return nil }
        let path = URL(string: href, relativeTo: home)?.path() ?? href
        let name = Self.cleanName(text.split(separator: "\n").first.map(String.init) ?? "")
        switch self {
        case .chatgpt:
            // The project's own link: /g/g-p-<id>[-slug][/project] — its text is the project's name.
            if let match = path.firstMatch(of: /^\/g\/(g-p-[A-Za-z0-9-]+)(\/project)?\/?$/) {
                let id = String(match.1)
                return AskProject(name: name.isEmpty ? Self.slugName(id) : name, url: "https://\(site)/g/\(id)/project")
            }
            // A chat inside a project: /g/g-p-<id>/c/<chat>. The sidebar often links only these, so they reveal
            // the project — but their text is the chat's title, not the project's name.
            if let match = path.firstMatch(of: /^\/g\/(g-p-[A-Za-z0-9-]+)\/c\//) {
                let id = String(match.1)
                return AskProject(name: Self.slugName(id), url: "https://\(site)/g/\(id)/project")
            }
            return nil
        case .claude:
            guard let match = path.firstMatch(of: /^\/project\/([0-9a-fA-F-]{36})\/?$/) else { return nil }
            return AskProject(name: name, url: "https://\(site)/project/\(match.1)")
        case .muse:
            return nil
        }
    }

    /// "g-p-67c8ab12cd-job-search" → "job search"; bare ids ("g-p-68e9b165…") have no name in them.
    private static func slugName(_ id: String) -> String {
        let parts = id.split(separator: "-").dropFirst(3)
        return parts.joined(separator: " ")
    }

    /// "Project 5ddd0b9"-style name from a project link's id, for when the real name can't be read.
    static func placeholderName(for url: String) -> String {
        let id = url.split(separator: "/").last { $0 != "project" } ?? ""
        return "Project \(id.suffix(6))"
    }

    /// Removes icon glyphs (private-use characters), invisible and control characters, which otherwise show up as
    /// "?" boxes, and tidies whitespace.
    static func cleanName(_ raw: String) -> String {
        let kept = raw.unicodeScalars.filter { scalar in
            let v = scalar.value
            let privateUse = (0xE000...0xF8FF).contains(v) || v >= 0xF0000
            let invisible = [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0xFFFC, 0xFFFD].contains(v)
            return !privateUse && !invisible && !CharacterSet.controlCharacters.contains(scalar)
        }
        return String(String.UnicodeScalarView(kept))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Reads a project page's name: its title without the site suffix, else the main heading.
    static let projectNameScript = """
    const clean = t => (t || '').replace(/\\s*[-|·–]\\s*(ChatGPT|Claude)\\s*$/i, '').trim();
    const title = clean(document.title);
    if (title && !/^(ChatGPT|Claude)$/i.test(title)) return title;
    const heading = document.querySelector('main h1, h1, main h2');
    return heading ? heading.innerText.trim() : '';
    """

    /// Lists every link on the page; filtering happens in Swift (`projects(fromLinks:)`).
    static let linkScript = """
    return [...document.querySelectorAll('a[href]')].slice(0, 3000).map(a => ({
      href: a.getAttribute('href') || '',
      name: (a.innerText || a.getAttribute('aria-label') || '').trim(),
    }));
    """
}
