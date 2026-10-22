import AppKit
import Foundation
import Testing
import WebKit
@testable import ChatApp

@MainActor @Suite(.serialized) struct ProjectScraperTests {
    /// A page whose sidebar fills in after load, like ChatGPT's.
    private func page(_ html: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "notchman-projects-\(UUID().uuidString).html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func waitsForTheSidebarToFillIn() async throws {
        let url = try page("""
        <html><body><nav id="side"></nav><script>
        setTimeout(() => {
          document.getElementById('side').innerHTML =
            '<a href="/g/g-p-67c8ab12cd-job-search/project">Job Search</a>' +
            '<a href="/g/g-p-67c8ab12cd-job-search/c/abc">A chat in it</a>' +
            '<a href="/g/g-p-99ff00-robotics/project">Robotics</a>' +
            '<a href="/c/plain">Plain chat</a>';
        }, 1500);
        </script></body></html>
        """)
        let result = try await ProjectScraper(service: .chatgpt, userAgent: nil, page: url).run(timeout: 8)
        #expect(result.projects.map(\.name) == ["Job Search", "Robotics"])
        #expect(result.projects.first?.url == "https://chatgpt.com/g/g-p-67c8ab12cd-job-search/project")
        #expect(result.linksSeen == 4)
    }

    @Test func emptyPagesReportWhatWasSeen() async throws {
        let url = try page("<html><body><a href=\"/c/1\">chat</a></body></html>")
        let result = try await ProjectScraper(service: .chatgpt, userAgent: nil, page: url).run(timeout: 2)
        #expect(result.projects.isEmpty && result.linksSeen == 1)
        #expect(ChatApp.ProjectLoadResult(added: 0, found: 0, linksSeen: 1).message.contains("No projects found"))
        #expect(ChatApp.ProjectLoadResult(added: 0, found: 0, linksSeen: 0).message.contains("didn't load"))
        #expect(ChatApp.ProjectLoadResult(added: 2, found: 3, linksSeen: 40).message == "Added 2 projects.")
    }

    @Test func readsAProjectsNameFromItsPage() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        func name(_ html: String) async throws -> String {
            web.loadHTMLString(html, baseURL: URL(string: "https://chatgpt.com/g/g-p-1/project"))
            for _ in 0..<40 where web.isLoading { try await Task.sleep(for: .milliseconds(50)) }
            return try await web.callAsyncJavaScript(ChatService.projectNameScript, arguments: [:], in: nil,
                                                     contentWorld: .defaultClient) as? String ?? ""
        }
        #expect(try await name("<html><head><title>Job Search - ChatGPT</title></head><body></body></html>") == "Job Search")
        #expect(try await name("<html><head><title>ChatGPT</title></head><body><main><h1>Robotics</h1></main></body></html>") == "Robotics")
        window.close()
    }

    @Test func claudeListsProjectsOnItsProjectsPage() {
        #expect(ProjectScraper.listPage(for: .claude).absoluteString == "https://claude.ai/projects")
        #expect(ProjectScraper.listPage(for: .chatgpt) == ChatService.chatgpt.home)
    }
}
