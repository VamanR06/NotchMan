import Foundation
import Testing
@testable import NotchKit

@Suite struct HookServerTests {
    @Test func parsesACompleteRequest() throws {
        let body = #"{"tool_name":"Bash"}"#
        let raw = "POST /permission?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer t\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let request = try #require(HookServer.parse(Data(raw.utf8)))
        #expect(request.method == "POST")
        #expect(request.path == "/permission")
        #expect(request.headers["authorization"] == "Bearer t")
        #expect(String(decoding: request.body, as: UTF8.self) == body)
    }

    @Test func servesRoutesOnlyWithTheToken() async throws {
        let server = HookServer.shared
        server.route("/test-echo") { request in HookServer.Response(body: request.body) }
        try await Task.sleep(for: .milliseconds(300))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(HookServer.port)/test-echo")!)
        request.httpMethod = "POST"
        request.httpBody = Data("ping".utf8)

        let (_, denied) = try await URLSession.shared.data(for: request)
        #expect((denied as? HTTPURLResponse)?.statusCode == 401)

        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        let (data, ok) = try await URLSession.shared.data(for: request)
        #expect((ok as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "ping")
    }

    @Test func waitsForTheWholeBody() {
        let partial = "POST /p HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345"
        #expect(HookServer.parse(Data(partial.utf8)) == nil)
        #expect(HookServer.parse(Data("POST /p HTTP/1.1\r\nContent-Length: 3".utf8)) == nil)
    }
}
