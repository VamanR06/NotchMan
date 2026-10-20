import Foundation
import Testing
@testable import NotchKit

@Suite struct LoopbackServerTests {
    @Test func receivesOAuthCallback() async throws {
        let server = try LoopbackServer()
        let port = try await server.start()

        // A stray request (like a favicon fetch) must not complete the flow.
        let favicon = URL(string: "http://127.0.0.1:\(port)/favicon.ico")!
        let (_, faviconResponse) = try await URLSession.shared.data(from: favicon)
        #expect((faviconResponse as? HTTPURLResponse)?.statusCode == 404)

        async let callback = server.waitForCallback()
        let redirect = URL(string: "http://127.0.0.1:\(port)/?code=abc123&state=xyz")!
        let (body, response) = try await URLSession.shared.data(from: redirect)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("connected"))

        let url = try await callback
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "code" }?.value == "abc123")
        #expect(items.first { $0.name == "state" }?.value == "xyz")
    }

    @Test func cancelFailsWaiter() async throws {
        let server = try LoopbackServer()
        _ = try await server.start()
        server.cancel()
        await #expect(throws: LoopbackServer.ServerError.self) { try await server.waitForCallback() }
    }
}

@Suite struct PKCETests {
    /// Example from RFC 7636, appendix B.
    @Test func matchesRFCExample() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func randomVerifiersDiffer() {
        #expect(PKCE().verifier != PKCE().verifier)
        #expect(PKCE().verifier.count == 64)
    }
}
