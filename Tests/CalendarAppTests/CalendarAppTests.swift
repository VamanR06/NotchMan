import Foundation
import Testing
@testable import CalendarApp

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
