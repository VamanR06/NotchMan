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
