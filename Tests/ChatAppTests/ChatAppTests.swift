import Foundation
import Testing
@testable import ChatApp

@MainActor @Suite struct LinkRoutingTests {
    private func stays(_ s: String) -> Bool { ChatWebCoordinator.staysInApp(URL(string: s)) }

    @Test func chatSitesAndSignInStayInNotch() {
        #expect(stays("https://chatgpt.com/c/123"))
        #expect(stays("https://auth.openai.com/log-in"))
        #expect(stays("https://claude.ai/new"))
        #expect(stays("https://accounts.google.com/o/oauth2/auth"))
        #expect(stays("https://appleid.apple.com/auth"))
        #expect(stays("https://muse.ai/"))
        #expect(stays("https://auth.muse.ai/aymh/"))
    }

    @Test func otherLinksGoToBrowser() {
        #expect(!stays("https://github.com/VamanR06"))
        #expect(!stays("https://en.wikipedia.org/wiki/Notch"))
        // Lookalike domains don't count as the real ones.
        #expect(!stays("https://evilchatgpt.com/"))
        #expect(!stays("https://claude.ai.example.com/"))
    }
}

@Suite struct ServicePageTests {
    @Test func onlyOpensPagesOnTheServicesOwnSite() {
        #expect(ChatService.chatgpt.page("https://chatgpt.com/g/g-p-1-jobs/project") != nil)
        #expect(ChatService.chatgpt.page("https://claude.ai/project/1") == nil)
        #expect(ChatService.chatgpt.page("https://chatgpt.com.evil.example/") == nil)
        #expect(ChatService.chatgpt.page("http://chatgpt.com/") == nil)
        #expect(ChatService.chatgpt.page(nil) == nil)
        #expect(ChatService.claude.page("https://claude.ai/project/abc") != nil)
    }
}

@Suite struct ProjectLinkParsingTests {
    @Test func findsChatGPTProjectsButNotTheirChats() {
        let links: [[String: String]] = [
            ["href": "/g/g-p-67c8ab12cd-job-search/project", "name": "Job Search"],
            ["href": "/g/g-p-67c8ab12cd-job-search/c/abc-123", "name": "Resume review"],  // a chat inside it
            ["href": "https://chatgpt.com/g/g-p-99ff00-robotics", "name": "Robotics\n3 chats"],
            ["href": "/g/g-p-1234abcd-untitled-thing", "name": ""],                     // name from slug
            ["href": "/c/plain-chat", "name": "Some chat"],
            ["href": "/g/g-abc-custom-gpt", "name": "A custom GPT"],                     // GPTs aren't projects
        ]
        let projects = ChatService.chatgpt.projects(fromLinks: links)
        #expect(projects.map(\.name) == ["Job Search", "Robotics", "untitled thing"])
        #expect(projects[0].url == "https://chatgpt.com/g/g-p-67c8ab12cd-job-search/project")
        #expect(projects[1].url == "https://chatgpt.com/g/g-p-99ff00-robotics/project")
    }

    @Test func findsClaudeProjects() {
        let links: [[String: String]] = [
            ["href": "/project/0198a7c2-1111-7abc-9def-0123456789ab", "name": "Thesis"],
            ["href": "/projects", "name": "Projects"],
            ["href": "/chat/0198a7c2-2222-7abc-9def-0123456789ab", "name": "A chat"],
        ]
        let projects = ChatService.claude.projects(fromLinks: links)
        #expect(projects.map(\.name) == ["Thesis"])
        #expect(projects.first?.url == "https://claude.ai/project/0198a7c2-1111-7abc-9def-0123456789ab")
    }

    @Test func museHasNoProjects() {
        #expect(!ChatService.muse.supportsProjects)
        #expect(ChatService.muse.projects(fromLinks: [["href": "/project/x", "name": "x"]]).isEmpty)
    }
}
