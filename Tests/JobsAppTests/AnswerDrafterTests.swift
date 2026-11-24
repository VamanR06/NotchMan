import AppKit
import CoreText
import Foundation
import SwiftUI
import Testing
@testable import JobsApp

@MainActor @Suite struct AnswerDrafterTests {
    let questions = [
        DraftItem(key: "question_123", label: "Why do you want to work at Acme?", required: true),
        DraftItem(key: "cover", label: "Anything else?", required: false),
    ]
    let context = DraftContext(company: "Acme", title: "Software Engineer", location: "Ann Arbor, MI",
                               posting: "Build robots.\n\n\n\nWith   lots    of space.", resume: "Built a parser at Initech.")

    @Test func oneSmallCappedRequestForEveryQuestion() throws {
        let data = AnswerDrafter.requestBody(questions: questions, context: context,
                                             settings: DraftSettings(model: "gemma3:4b", keepAlive: .minute))
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "gemma3:4b")
        #expect(body["stream"] as? Bool == true)
        #expect(body["think"] as? Bool == false)
        #expect(body["keep_alive"] as? String == "60s")
        let options = try #require(body["options"] as? [String: Any])
        #expect(options["num_ctx"] as? Int == 4096)
        #expect(options["num_predict"] as? Int == 480)
        let format = try #require(body["format"] as? [String: Any])
        #expect(format["required"] as? [String] == ["q1", "q2"])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        let prompt = try #require(messages.last?["content"])
        #expect(prompt.contains("Role: Software Engineer at Acme (Ann Arbor, MI)"))
        #expect(prompt.contains("q1: Why do you want to work at Acme?\nq2: Anything else? (optional)"))
        #expect(prompt.contains("Built a parser at Initech."))
        #expect(prompt.contains("Build robots.\n\nWith lots of space."))

        let many = Array(repeating: questions[0], count: 9)
        let capped = try #require(JSONSerialization.jsonObject(with: AnswerDrafter.requestBody(
            questions: many, context: context, settings: DraftSettings())) as? [String: Any])
        #expect((capped["options"] as? [String: Any])?["num_predict"] as? Int == 900)
        let plain = try #require(JSONSerialization.jsonObject(with: AnswerDrafter.requestBody(
            questions: questions, context: context, settings: DraftSettings(keepAlive: .none), think: false)) as? [String: Any])
        #expect(plain["think"] == nil)
        #expect(plain["keep_alive"] as? String == "0s")
    }

    @Test func longPostingsAndResumesAreTrimmedAtAWord() {
        let long = String(repeating: "word ", count: 2_000)
        let trimmed = DraftContext(company: "A", title: "B", location: "", posting: long, resume: "  \n ")
        #expect(trimmed.posting.count <= DraftContext.maxPosting + 2)
        #expect(trimmed.posting.hasSuffix("word …"))
        #expect(trimmed.resume == nil, "a blank resume counts as none")
        #expect(trimmed.location == nil)
        #expect(AnswerDrafter.userPrompt(questions: questions, context: trimmed).contains("(no resume attached"))
    }

    @Test func readsAnswersWhileTheyStream() {
        let partial = #"{"q1": "I built \"Rover\"\nat Initech and lov"#
        let answers = AnswerDrafter.answers(in: partial, questions: questions)
        #expect(answers["question_123"] == "I built \"Rover\"\nat Initech and lov")
        #expect(answers["cover"] == nil)

        let done = #"{"q1":"First.","q2" : "Café time."}"#
        let full = AnswerDrafter.answers(in: done, questions: questions)
        #expect(full == ["question_123": "First.", "cover": "Café time."])
        #expect(AnswerDrafter.partialString(for: "q2", in: #"{"q1":"#) == nil)
        #expect(AnswerDrafter.partialString(for: "q1", in: #"{"q1":"#) == "")
        // "q1" must not match inside "q10".
        #expect(AnswerDrafter.partialString(for: "q1", in: #"{"q10":"x","q1":"y"}"#) == "y")
    }

    @Test func resumeTextComesFromPDFAndText() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "drafter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let pdf = folder.appending(path: "Resume.pdf")
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Built a parser at Initech",
                                                                       attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        try (data as Data).write(to: pdf)
        #expect(DraftContext.resumeText(from: pdf)?.contains("Built a parser at Initech") == true)

        let txt = folder.appending(path: "Resume.txt")
        try "Plain resume".write(to: txt, atomically: true, encoding: .utf8)
        #expect(DraftContext.resumeText(from: txt) == "Plain resume")
        #expect(DraftContext.resumeText(from: folder.appending(path: "missing.pdf")) == nil)
    }

    @Test func onlyUnansweredOpenQuestionsAreDraftable() throws {
        let decoded = try JSONDecoder().decode(FieldPlan.self, from: Data(#"""
            {"key":"why","label":"Why us?","kind":"textarea","required":true,"status":"unknown","category":"narrative",
             "source":null,"note":"Write this answer"}
            """#.utf8))
        #expect(decoded.category == "narrative")
        let plans = [
            decoded,
            FieldPlan(key: "pitch", label: "Tell us about a project", kind: "text", required: false, status: "unknown", note: nil, category: "narrative"),
            FieldPlan(key: "saved", label: "Why Acme?", kind: "textarea", required: true, status: "resolved", note: nil, category: "narrative"),
            FieldPlan(key: "agree", label: "I certify", kind: "checkbox", required: true, status: "unknown", note: nil, category: "attestation"),
            FieldPlan(key: "visa", label: "Sponsorship details", kind: "textarea", required: true, status: "unknown", note: nil, category: "eligibility"),
            FieldPlan(key: "old", label: "Comments", kind: "textarea", required: false, status: "unknown", note: nil),
            decoded,
        ]
        let report = AutofillReport.from(plans: plans, results: [])
        #expect(report.draftable.map(\.key) == ["why", "pitch", "old"], "older JobManager (no category): textareas")
        #expect(report.draftable.first?.required == true)
    }

    @Test func insertTypesIntoTheScannedField() {
        let field: [String: Any] = ["key": "why", "selector": "#q_1", "kind": "textarea", "inputType": "",
                                    "label": "Why us?", "options": []]
        let step = PageForm.step(for: field, answer: "Because.")
        #expect(step["selector"] as? String == "#q_1")
        #expect(step["kind"] as? String == "textarea")
        #expect(step["answer"] as? String == "Because.")
        #expect(step["upload"] is NSNull)
        #expect(JSONSerialization.isValidJSONObject([step]))
    }

    /// Renders the This Page card before, during and after drafting into build/dev for eyeballing.
    @Test func rendersDraftStates() throws {
        let info = PageInfo(job: .init(id: 1, company: "Acme Robotics", title: "Software Engineer Intern", url: nil),
                            resume: .init(id: 2, name: "Resume.pdf"), cover_letter: nil)
        let match = PageMatch(tab: BrowserTabRef(url: URL(string: "https://boards.greenhouse.io/acme/jobs/1")!, bundleID: "", browser: "Chrome"),
                              info: info)
        var report = AutofillReport(filled: 14, needsYou: ["Why Acme? — Write this answer", "A project you're proud of — Write this answer"])
        report.attached = ["Resume"]
        let blank = [DraftItem(key: "why", label: "Why do you want to work at Acme Robotics?", required: true),
                     DraftItem(key: "project", label: "Tell us about a project you're proud of.", required: true)]
        var written = blank
        written[0].text = "Acme's work on warehouse robots that pick irregular items is the problem I most want to work on. At Initech I built the parser that turned sensor logs into test fixtures, which cut our debugging time in half, and I'd like to bring that habit of building tools for the team to Acme's controls group."
        written[1].text = "I wrote a path planner for my university's rover team in Rust, replacing a Python prototype that couldn't keep up at full speed."
        written[0].inserted = true
        var streaming = blank
        streaming[0].text = "Acme's work on warehouse robots that pick irregular items is"

        func card(_ drafts: [DraftItem], drafting: Bool) -> some View {
            let app = JobsApp()
            app.useDraftsForTesting(match: match, report: report, drafts: drafts, drafting: drafting)
            return ThisPageCard(app: app, match: match)
        }
        let view = VStack(alignment: .leading, spacing: 14) {
            card(blank, drafting: false)
            card(streaming, drafting: true)
            card(written, drafting: false)
        }
            .padding(14)
            .frame(width: 560)
            .background(.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let tiff = try #require(renderer.nsImage?.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../build/dev").standardizedFileURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appending(path: "answer-drafts.png"))
    }

    @Test func modelNamesAndErrors() {
        #expect(AnswerDrafter.has("gemma3:4b", in: ["gemma3:4b", "llama3.2:latest"]))
        #expect(AnswerDrafter.has("llama3.2", in: ["llama3.2:latest"]))
        #expect(!AnswerDrafter.has("qwen3:4b", in: ["qwen3:8b"]))
        let refused = AnswerDrafter.friendly(URLError(.cannotConnectToHost))
        #expect(refused as? AnswerDrafter.DraftError == .notRunning)
        #expect(AnswerDrafter.DraftError.missingModel("gemma3:4b").errorDescription?.contains("ollama pull gemma3:4b") == true)
    }
}
