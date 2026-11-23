import Foundation
import Testing
@testable import NotchKit

/// Recorded request bodies, so a test can check what would have left the Mac.
private final class Sent: @unchecked Sendable {
    var bodies: [String] = []
}

@MainActor @Suite(.serialized) struct JevTests {
    private let questions: [String: JevQuestion] = [
        "c1": .score("How likely is it that the file belongs in `candidates.c1`?", levels: ["unlikely", "possible", "likely"]),
        "move": .noul("Does the user want to move it?"),
        "kind": .choice("What is the file?", ["resume": "a résumé", "other": "anything else"]),
    ]

    private let reply = """
    {"model":"jev-1.14.0","answers":{
      "c1":{"type":"score","score":1.5,"confidence":0.4,"probabilities":{"0":0.1,"1":0.3,"2":0.6}},
      "move":{"type":"noul","noul":0.92},
      "kind":{"type":"choice","choice":"resume","confidence":0.8,"probabilities":{"resume":0.9,"other":0.1}}},
      "usage":{"input_tokens":120,"output_tokens":3}}
    """

    private func withJev(privacy: JevPrivacy, key: String? = "test-key", identity: [String] = ["Jane Doe"],
                         status: Int = 200, _ body: (Sent) async throws -> Void) async throws {
        let sent = Sent()
        let reply = Data(self.reply.utf8)
        let environment = JevTestEnvironment(privacy: privacy, apiKey: key, identity: identity) { request in
            sent.bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            return (reply, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        try await JevTestEnvironment.$current.withValue(environment) { try await body(sent) }
    }

    @Test func asksEveryQuestionInOneRequestAndReadsTheAnswers() async throws {
        try await withJev(privacy: .redacted) { sent in
            let answers = try await Jev.ask(state: ["file": "MY_NAME_Resume.pdf"], questions: questions)
            #expect(sent.bodies.count == 1)
            #expect(sent.bodies[0].contains(#""model":"jev-latest""#))
            #expect(sent.bodies[0].contains(#""criteria":["unlikely","possible","likely"]"#))
            #expect(answers["c1"] == .score(1.5, confidence: 0.4, levels: 3))
            #expect(answers["c1"]?.normalized == 0.75)
            #expect(answers["move"] == .noul(0.92))
            #expect(answers["kind"] == .choice("resume", confidence: 0.8, probabilities: ["resume": 0.9, "other": 0.1]))
        }
    }

    @Test func somethingPersonalLeftInIsNeverSent() async throws {
        try await withJev(privacy: .redacted) { sent in
            await #expect(throws: JevError.self) {
                _ = try await Jev.ask(state: ["file": "Jane_Doe_Resume.pdf"], questions: questions)
            }
            #expect(sent.bodies.isEmpty)
            #expect(JevLog.shared.entries.contains { $0.outcome.hasPrefix("held back") })
        }
    }

    @Test func redactingFirstMakesItSafeToSend() async throws {
        try await withJev(privacy: .redacted) { sent in
            let redactor = Jev.redactor()
            let state: JSONValue = ["file": .string(redactor.text("Jane_Doe_Resume.pdf", as: .fileName))]
            _ = try await Jev.ask(state: state, questions: questions)
            #expect(sent.bodies.count == 1 && !sent.bodies[0].lowercased().contains("jane"))
        }
    }

    @Test func offOrWithoutAKeyNothingIsSent() async throws {
        try await withJev(privacy: .off) { sent in
            await #expect(throws: JevError.unavailable) { _ = try await Jev.ask(state: "x", questions: questions) }
            #expect(sent.bodies.isEmpty)
        }
        try await withJev(privacy: .redacted, key: nil) { sent in
            await #expect(throws: JevError.unavailable) { _ = try await Jev.ask(state: "x", questions: questions) }
            #expect(sent.bodies.isEmpty)
        }
    }

    @Test func fullSendsAsIs() async throws {
        try await withJev(privacy: .full) { sent in
            let redactor = Jev.redactor()
            #expect(redactor.text("Jane_Doe_Resume.pdf", as: .fileName) == "Jane_Doe_Resume.pdf")
            _ = try await Jev.ask(state: ["file": "Jane_Doe_Resume.pdf"], questions: questions)
            #expect(sent.bodies.count == 1)
        }
    }

    @Test func anErrorStatusIsReported() async throws {
        try await withJev(privacy: .redacted, status: 422) { _ in
            await #expect(throws: JevError.self) { _ = try await Jev.ask(state: "x", questions: questions) }
        }
    }
}
