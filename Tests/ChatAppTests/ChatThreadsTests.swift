import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import ChatApp

@Suite struct ChatThreadParsingTests {
    private func id(_ service: ChatService, _ url: String) -> String? {
        URL(string: url).flatMap { service.conversation(at: $0)?.id }
    }

    @Test func recognizesConversationPages() {
        #expect(id(.chatgpt, "https://chatgpt.com/c/6ad9509a-55f8-8000-9a3b-1c2d3e4f5a6b") == "6ad9509a-55f8-8000-9a3b-1c2d3e4f5a6b")
        #expect(id(.chatgpt, "https://chatgpt.com/g/g-p-68e9b165-jobs/c/6ad9509a-55f8") == "6ad9509a-55f8")
        #expect(id(.chatgpt, "https://chatgpt.com/") == nil)
        #expect(id(.chatgpt, "https://chatgpt.com/g/g-p-68e9b165/project") == nil)
        #expect(id(.claude, "https://claude.ai/chat/0198A7C2-2222-7abc-9def-0123456789ab") == "0198a7c2-2222-7abc-9def-0123456789ab")
        #expect(id(.claude, "https://claude.ai/new") == nil)
        #expect(id(.claude, "https://claude.ai/project/0198a7c2-2222-7abc-9def-0123456789ab") == nil)
        #expect(id(.muse, "https://muse.ai/chat/a1b2c3d4e5") == "a1b2c3d4e5")
        #expect(id(.muse, "https://muse.ai/settings/a1b2c3d4e5") == nil)
        #expect(id(.muse, "https://muse.ai/explore") == nil)
        // Another site's page never counts.
        #expect(id(.chatgpt, "https://claude.ai/chat/0198a7c2-2222-7abc-9def-0123456789ab") == nil)
    }

    @Test func pageTitlesBecomeChatTitles() {
        #expect(ChatService.chatTitle(fromPageTitle: "Resume review - Claude") == "Resume review")
        #expect(ChatService.chatTitle(fromPageTitle: "Trip plan | ChatGPT") == "Trip plan")
        #expect(ChatService.chatTitle(fromPageTitle: "ChatGPT") == "")
        #expect(ChatService.chatTitle(fromPageTitle: "New chat") == "")
        #expect(ChatService.chatTitle(fromPageTitle: "Claude") == "")
    }

    @Test func readsTheSitesListThenTheSidebarsExtraChats() {
        let result: [String: Any] = [
            "api": [
                ["id": "aaa11111-1", "title": "Newest", "updated": 1_762_400_000_000.0, "project": ""],
                ["id": "bbb22222-2", "title": "In a project", "updated": 1_762_300_000_000.0,
                 "project": "g-p-67c8ab12cd"],
                ["id": "ccc33333-3", "title": "Custom GPT chat", "updated": 0, "project": "g-abc"],
            ],
            "links": [
                ["href": "/c/aaa11111-1", "name": "Newest"],                                  // already listed
                ["href": "/g/g-p-99ff00-robotics/c/ddd44444-4", "name": "Arm kinematics\n2 days"],
                ["href": "/g/g-p-99ff00-robotics/project", "name": "Robotics"],               // a project, not a chat
                ["href": "https://example.com/c/eee55555-5", "name": "Elsewhere"],
            ],
        ]
        let threads = ChatService.chatgpt.threads(fromList: result, projectNames: ["g-p-67c8ab12cd": "Job Search"])
        #expect(threads.map(\.title) == ["Newest", "In a project", "Custom GPT chat", "Arm kinematics"])
        #expect(threads[0].url == "https://chatgpt.com/c/aaa11111-1")
        #expect(threads[0].updated == Date(timeIntervalSince1970: 1_762_400_000))
        #expect(threads[1].project == "Job Search")
        #expect(threads[2].project == nil && threads[2].updated == nil)
        #expect(threads[3].project == "robotics")
        #expect(threads[3].url == "https://chatgpt.com/g/g-p-99ff00-robotics/c/ddd44444-4")
    }

    @Test func readsClaudesList() {
        let result: [String: Any] = [
            "api": [["id": "0198A7C2-2222-7ABC-9DEF-0123456789AB", "title": "Thesis outline",
                     "updated": 1_762_400_000_000.0, "project": "Thesis"]],
            "links": [["href": "/chat/0198a7c2-2222-7abc-9def-0123456789ab", "name": "Thesis outline"]],
        ]
        let threads = ChatService.claude.threads(fromList: result)
        #expect(threads.count == 1)
        #expect(threads.first?.url == "https://claude.ai/chat/0198A7C2-2222-7ABC-9DEF-0123456789AB")
        #expect(threads.first?.conversationID == "0198a7c2-2222-7abc-9def-0123456789ab")
        #expect(threads.first?.project == "Thesis")
    }
}

@Suite struct ChatThreadListTests {
    private let now = Date(timeIntervalSince1970: 1_762_430_400)  // a Thursday afternoon

    private func thread(_ id: String, _ service: ChatService = .chatgpt, title: String = "",
                        updated: Date? = nil, opened: Date? = nil, project: String? = nil) -> ChatThread {
        ChatThread(service: service, conversationID: id, url: "https://chatgpt.com/c/\(id)", title: title,
                   project: project, updated: updated, opened: opened)
    }

    @Test func mergingKeepsTheNewestOfEverything() {
        let old = [thread("a", title: "Old title", updated: now.addingTimeInterval(-500), project: "Jobs")]
        let merged = ChatThreads.merge(old, [
            thread("a", title: "", opened: now),                         // opened: keeps the title, adds the time
            thread("b", title: "New one", updated: now.addingTimeInterval(-50)),
        ])
        #expect(merged.map(\.id) == ["chatgpt:a", "chatgpt:b"])
        #expect(merged[0].title == "Old title" && merged[0].project == "Jobs")
        #expect(merged[0].opened == now && merged[0].lastActive == now)
        let renamed = ChatThreads.merge(merged, [thread("a", title: "Renamed", updated: now.addingTimeInterval(-900))])
        #expect(renamed[0].title == "Renamed")
        #expect(renamed[0].updated == now.addingTimeInterval(-500), "an older time doesn't win")
    }

    @Test func sortsNewestFirstThenUndatedInSiteOrder() {
        let sorted = ChatThreads.sorted([
            thread("x"), thread("old", updated: now.addingTimeInterval(-9000)), thread("y"),
            thread("new", opened: now),
        ])
        #expect(sorted.map(\.conversationID) == ["new", "old", "x", "y"])
    }

    @Test func groupsByDayWithPinnedFirst() {
        let day: TimeInterval = 86_400
        let threads = [
            thread("today", updated: now.addingTimeInterval(-60)),
            thread("yesterday", updated: now.addingTimeInterval(-day)),
            thread("week", updated: now.addingTimeInterval(-4 * day)),
            thread("month", updated: now.addingTimeInterval(-20 * day)),
            thread("older", updated: now.addingTimeInterval(-90 * day)),
            thread("undated"),
            thread("pinned", updated: now.addingTimeInterval(-90 * day)),
        ]
        let groups = ChatThreads.grouped(threads, pinned: ["chatgpt:pinned"], now: now)
        #expect(groups.map(\.section) == [.pinned, .today, .yesterday, .week, .month, .older])
        #expect(groups.last?.threads.map(\.conversationID) == ["older", "undated"])
    }

    @Test func searchMatchesEveryWordInTitleProjectOrService() {
        let chat = thread("a", .claude, title: "Resume review", project: "Job Search")
        #expect(ChatThreads.matches(chat, query: "resume job"))
        #expect(ChatThreads.matches(chat, query: "claude"))
        #expect(ChatThreads.matches(chat, query: "  "))
        #expect(!ChatThreads.matches(chat, query: "resume robotics"))
    }

    @Test func aCompleteSyncDropsDeletedChatsOfThatServiceOnly() {
        let existing = [
            thread("kept", title: "Kept"), thread("deleted"), thread("pinned-deleted"),
            thread("claude-chat", .claude),
        ]
        let synced = ChatThreads.replacing(existing, with: [thread("kept", title: "Renamed"), thread("new")],
                                           for: .chatgpt, pinned: ["chatgpt:pinned-deleted"])
        #expect(synced.map(\.conversationID) == ["kept", "pinned-deleted", "claude-chat", "new"])
        #expect(synced[0].title == "Renamed")
    }

    @Test func trimmingKeepsTheNewestAndThePinned() {
        let threads = (0..<5).map { thread("t\($0)", updated: now.addingTimeInterval(Double(-$0) * 60)) }
        let kept = ChatThreads.trimmed(threads, pinned: ["chatgpt:t4"], perService: 2)
        #expect(Set(kept.map(\.conversationID)) == ["t0", "t1", "t4"])
    }
}

@MainActor @Suite(.serialized) struct ChatListScriptTests {
    /// Loads `html` as if it were the site and runs the service's list script in the page's world, where the
    /// page's stand-in `fetch` (the site's list) is visible.
    private func run(_ service: ChatService, _ html: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        defer { window.close() }
        web.loadHTMLString(html, baseURL: service.home)
        for _ in 0..<60 where web.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        return try await web.callAsyncJavaScript(service.chatListScript, arguments: arguments, in: nil,
                                                 contentWorld: .page) as? [String: Any] ?? [:]
    }

    @Test func chatGPTsListUsesTheSessionToken() async throws {
        let result = try await run(.chatgpt, """
        <html><body><a href="/c/fff66666-6">From the sidebar</a><script>
        window.fetch = async (url, options) => {
          if (url === '/api/auth/session') return { ok: true, json: async () => ({ accessToken: 'tok' }) };
          const authorized = options.headers.Authorization === 'Bearer tok';
          return { ok: authorized, json: async () => ({ items: [
            { id: 'aaa11111-1', title: 'Trip plan', update_time: '2025-11-06T12:00:00.000000Z', gizmo_id: null },
            { id: 'bbb22222-2', title: 'Older', update_time: 1762300000.5 },
          ] }) };
        };
        </script></body></html>
        """)
        let threads = ChatService.chatgpt.threads(fromList: result)
        #expect(threads.map(\.title) == ["Trip plan", "Older", "From the sidebar"])
        #expect(threads[0].updated == ISO8601DateFormatter().date(from: "2025-11-06T12:00:00Z"))
        #expect(threads[1].updated.map { abs($0.timeIntervalSince1970 - 1_762_300_000.5) < 0.01 } == true)
    }

    @Test func claudesListCoversEachOrganization() async throws {
        let result = try await run(.claude, """
        <html><body><script>
        window.fetch = async (url) => {
          if (url === '/api/organizations') return { ok: true, json: async () => [{ uuid: 'org1' }, { uuid: 'org2' }] };
          const org = url.split('/')[3];
          return { ok: org === 'org1', json: async () => [
            { uuid: '0198a7c2-2222-7abc-9def-0123456789ab', name: 'Thesis outline',
              updated_at: '2025-11-06T12:00:00.123456Z', project: { name: 'Thesis' } },
          ] };
        };
        </script></body></html>
        """)
        let threads = ChatService.claude.threads(fromList: result)
        #expect(threads.map(\.title) == ["Thesis outline"])
        #expect(threads.first?.project == "Thesis")
        #expect(threads.first?.updated != nil)
    }

    /// A ChatGPT stand-in with 250 chats in pages of 100, and a project (linked in the sidebar) with 3 more in
    /// pages of 2. `failProject` makes the project's list fail.
    private func chatGPTWithHistory(failProject: Bool = false) -> String {
        """
        <html><body><a href="/g/g-p-abc123-robotics/project">Robotics</a><script>
        const chats = Array.from({ length: 250 }, (_, i) => ({ id: 'chat' + String(i).padStart(4, '0'),
          title: 'Chat ' + i, update_time: 1762300000 - i }));
        const projectChats = [1, 2, 3].map(i => ({ id: 'proj000' + i, title: 'Project chat ' + i, update_time: 1762200000 }));
        window.fetch = async (url) => {
          const json = body => ({ ok: true, json: async () => body });
          if (url === '/api/auth/session') return json({ accessToken: 'tok' });
          const query = new URLSearchParams(url.split('?')[1]);
          if (url.startsWith('/backend-api/conversations')) {
            const offset = +query.get('offset'), limit = +query.get('limit');
            return json({ items: chats.slice(offset, offset + limit), total: chats.length });
          }
          if (url.startsWith('/backend-api/gizmos/g-p-abc123/conversations')) {
            if (\(failProject)) return { ok: false };
            const cursor = +query.get('cursor');
            const next = cursor + 2 < projectChats.length ? cursor + 2 : null;
            return json({ items: projectChats.slice(cursor, cursor + 2), cursor: next });
          }
          return { ok: false };
        };
        </script></body></html>
        """
    }

    @Test func aQuickReadTakesTheNewestHundred() async throws {
        let result = try await run(.chatgpt, chatGPTWithHistory())
        #expect(ChatService.chatgpt.threads(fromList: result).count == 100)
        #expect(result["complete"] as? Bool == false)
    }

    @Test func aFullReadTakesEveryPageAndEachProject() async throws {
        let result = try await run(.chatgpt, chatGPTWithHistory(), arguments: ["full": true])
        let threads = ChatService.chatgpt.threads(fromList: result, projectNames: ["g-p-abc123": "Robotics"])
        #expect(threads.count == 253)
        #expect(threads.filter { $0.project == "Robotics" }.map(\.title) == ["Project chat 1", "Project chat 2", "Project chat 3"])
        #expect(result["complete"] as? Bool == true)
    }

    @Test func aFailedProjectMeansTheReadIsntComplete() async throws {
        let result = try await run(.chatgpt, chatGPTWithHistory(failProject: true), arguments: ["full": true])
        #expect(ChatService.chatgpt.threads(fromList: result).count == 250)
        #expect(result["complete"] as? Bool == false)
    }

    @Test func claudeWithoutPagingIsReadWhole() async throws {
        // This stand-in ignores `offset`: every page is the first 100, and only the plain list has all 150.
        let result = try await run(.claude, """
        <html><body><script>
        const chats = Array.from({ length: 150 }, (_, i) => ({
          uuid: '0198a7c2-0000-7abc-9def-' + String(i).padStart(12, '0'), name: 'Chat ' + i, updated_at: '2025-11-06T12:00:00Z' }));
        window.fetch = async (url) => {
          const json = body => ({ ok: true, json: async () => body });
          if (url === '/api/organizations') return json([{ uuid: 'org1' }]);
          return json(url.includes('?') ? chats.slice(0, 100) : chats);
        };
        </script></body></html>
        """, arguments: ["full": true])
        #expect(ChatService.claude.threads(fromList: result).count == 150)
        #expect(result["complete"] as? Bool == true)
    }

    @Test func fallsBackToTheSidebarWhenTheListFails() async throws {
        let result = try await run(.claude, """
        <html><body><a href="/chat/0198a7c2-3333-7abc-9def-0123456789ab">Sidebar chat</a>
        <a href="/projects">Projects</a>
        <script>window.fetch = async () => { throw new Error('offline'); };</script></body></html>
        """)
        #expect(result["api"] is NSNull || result["api"] == nil)
        #expect(ChatService.claude.threads(fromList: result).map(\.title) == ["Sidebar chat"])
    }
}

@MainActor @Suite struct ChatListRenderTests {
    /// Renders the Chats list into build/dev for eyeballing.
    @Test func rendersChatList() throws {
        let now = Date()
        func chat(_ id: String, _ service: ChatService, _ title: String, ago: TimeInterval?, project: String? = nil) -> ChatThread {
            ChatThread(service: service, conversationID: id, url: "https://chatgpt.com/c/\(id)", title: title,
                       project: project, updated: ago.map { now.addingTimeInterval(-$0) })
        }
        let app = ChatApp()
        app.useChatsForTesting([
            chat("1", .claude, "NotchMan chat list design", ago: 300, project: "NotchMan"),
            chat("2", .chatgpt, "Cover letter for robotics internship", ago: 3600, project: "Job Search"),
            chat("3", .muse, "Moodboard ideas", ago: 7200),
            chat("4", .chatgpt, "Trip plan: Chicago weekend", ago: 90_000),
            chat("5", .claude, "Thesis outline — chapter 3", ago: 4 * 86_400, project: "Thesis"),
            chat("6", .chatgpt, "Linear algebra problem set 7", ago: 20 * 86_400),
            chat("7", .claude, "", ago: nil),
            chat("8", .chatgpt, "Interview prep questions", ago: 40 * 86_400, project: "Job Search"),
        ], pinned: ["chatgpt:8"])
        app.chatListSelection.index = 1
        let view = ChatListRows(app: app, groups: ChatThreads.grouped(app.shownChats, pinned: app.pinnedChats))
            .padding(14)
            .frame(width: 720, height: 430, alignment: .top)
            .background(.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let tiff = try #require(renderer.nsImage?.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../build/dev").standardizedFileURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appending(path: "chat-list.png"))
    }
}
