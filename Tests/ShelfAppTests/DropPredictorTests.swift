import Foundation
import Testing
@testable import NotchKit
@testable import ShelfApp

@MainActor @Suite(.serialized) struct DropPredictorTests {
    private let home = URL(fileURLWithPath: NSHomeDirectory())
    private var resumes: URL { home.appending(path: "Documents/Resumes") }
    private var taxes: URL { home.appending(path: "Documents/Taxes") }
    private var project: URL { home.appending(path: "GitHub/NotchMan") }
    private var downloads: URL { home.appending(path: "Downloads") }

    private func candidates() -> [DropCandidate] {
        DropRanking.candidates(recents: [project, taxes], projects: [project], places: [downloads], extra: [resumes, taxes])
    }

    @Test func candidatesKeepTheirFirstKindAndDontRepeat() {
        let all = candidates()
        #expect(all.map(\.url.lastPathComponent) == ["NotchMan", "Taxes", "Downloads", "Resumes"])
        #expect(all[0].kind == .recent && all[0].recencyRank == 0)
        #expect(all[3].kind == .folder)
    }

    @Test func matchingNamesAndPastDropsRankFirstLocally() {
        let file = URL(fileURLWithPath: "/tmp/Jane_Doe_Resume_2026.pdf")
        var history = DropHistory()
        let top = DropPredictor.top(candidates(), scores: Dictionary(uniqueKeysWithValues: candidates().map {
            ($0.id, DropRanking.localScore(files: [file], candidate: $0, history: history))
        }))
        #expect(top.count == 3)
        #expect(top[0].candidate.url == resumes, "a folder named for the file leads")
        #expect(top[1].candidate.url == project, "then the most recent folder")

        history.record([URL(fileURLWithPath: "/tmp/old.pdf"), URL(fileURLWithPath: "/tmp/older.pdf")], into: resumes)
        let score = DropRanking.localScore(files: [file], candidate: candidates()[3], history: history)
        #expect(abs(score - (0.45 + 0.35)) < 1e-9, "all past PDFs went there, and the name matches")
    }

    @Test func wordsMatchAcrossPluralsAndSeparators() {
        #expect(!DropRanking.words("Jane_Doe-resume.v2").isDisjoint(with: DropRanking.words("Resumes")))
        #expect(DropRanking.words("IMG_0042").isDisjoint(with: DropRanking.words("Resumes")))
    }

    @Test func theRequestToJevIsRedacted() {
        let redactor = Redactor(identity: ["Jane Doe"])
        let file = URL(fileURLWithPath: "/tmp/Jane_Doe_Resume.pdf")
        let request = DropRanking.request(files: [file], candidates: candidates(), history: DropHistory(),
                                          context: IntentContext(frontmostApp: "Safari", timeOfDay: "weekday morning"),
                                          redactor: redactor)
        #expect(request.questions.count == 4 && request.keys.count == 4)
        #expect(Redactor.leaks(in: request.state, identity: ["Jane Doe"]).isEmpty)
        let text = String(decoding: try! JSONEncoder.sorted.encode(request.state), as: UTF8.self)
        #expect(text.contains("MY_NAME_MY_NAME_Resume.pdf") || text.contains("MY_NAME_Resume.pdf"), "\(text)")
        #expect(text.contains("~/Documents/Resumes") && !text.contains(NSHomeDirectory()))
        #expect(request.keys["c4"]?.url == resumes)
    }

    @Test func jevsAnswerReordersTheSuggestions() async throws {
        // c4 (Resumes) very likely, c3 (Downloads) possible, the rest wrong.
        let reply = Data("""
        {"answers":{"c1":{"type":"score","score":0.2},"c2":{"type":"score","score":0.1},
        "c3":{"type":"score","score":1.5},"c4":{"type":"score","score":2.9}}}
        """.utf8)
        let environment = JevTestEnvironment(privacy: .redacted, apiKey: "test-key", identity: ["Jane Doe"]) { request in
            (reply, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try await JevTestEnvironment.$current.withValue(environment) { try await reorders() }
    }

    private func reorders() async throws {
        let predictor = DropPredictor()
        predictor.predict(files: [URL(fileURLWithPath: "/tmp/cv.pdf")], candidates: candidates(), history: DropHistory(),
                          context: IntentContext(frontmostApp: nil, timeOfDay: "weekday morning"))
        #expect(predictor.suggestions.first?.candidate.url == project, "local ranking shows at once")
        for _ in 0..<50 where !predictor.usedJev { try await Task.sleep(for: .milliseconds(20)) }
        #expect(predictor.usedJev)
        #expect(predictor.suggestions.map(\.candidate.url) == [resumes, downloads, project])
    }

    @Test func withoutJevItStaysLocal() {
        let environment = JevTestEnvironment(privacy: .off, apiKey: nil, identity: []) { _ in throw URLError(.notConnectedToInternet) }
        JevTestEnvironment.$current.withValue(environment) {
            let predictor = DropPredictor()
            predictor.predict(files: [URL(fileURLWithPath: "/tmp/a.pdf")], candidates: candidates(), history: DropHistory(),
                              context: IntentContext(frontmostApp: nil, timeOfDay: "x"))
            #expect(predictor.suggestions.count == 3 && !predictor.isRefining && !predictor.usedJev)
        }
    }
}
