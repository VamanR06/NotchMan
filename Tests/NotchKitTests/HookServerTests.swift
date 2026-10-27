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
        // Its own port, so a running NotchMan on the default one doesn't answer instead.
        let port = UInt16.random(in: 50_000...59_999)
        let server = HookServer(port: port)
        server.route("/test-echo") { request in HookServer.Response(body: request.body) }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/test-echo")!)
        request.httpMethod = "POST"
        request.httpBody = Data("ping".utf8)

        // The listener starts in the background; on a busy test machine give it up to 2s.
        var denied: URLResponse?
        for _ in 0..<20 where denied == nil {
            denied = try? await URLSession.shared.data(for: request).1
            if denied == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
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
