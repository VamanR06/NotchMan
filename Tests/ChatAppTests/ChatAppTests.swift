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
    }

    @Test func otherLinksGoToBrowser() {
        #expect(!stays("https://github.com/VamanR06"))
        #expect(!stays("https://en.wikipedia.org/wiki/Notch"))
        // Lookalike domains don't count as the real ones.
        #expect(!stays("https://evilchatgpt.com/"))
        #expect(!stays("https://claude.ai.example.com/"))
    }
}
