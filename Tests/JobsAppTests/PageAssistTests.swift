import Foundation
import Testing
@testable import JobsApp

@MainActor @Suite struct PageAssistTests {
    @Test func scriptsSayWhichJobsFillWorkExperience() throws {
        let decode = { (json: String) in try JSONDecoder().decode(ApplyScripts.self, from: Data(json.utf8)) }
        let old = try decode(#"{"scan":"s","fill":"f","frames":"r"}"#)
        #expect(old.experience == nil && old.sections == nil, "JobManager before v0.31")
        let fromResume = try decode(#"""
            {"scan":"s","fill":"f","frames":"r","add_sections":"a","sections":{"work":2},
             "experience":{"companies":["Acme Inc.","Initech"],"from_resume":true,"note":null}}
            """#)
        #expect(fromResume.sections?.work == 2)
        #expect(fromResume.experience?.summary == "From your resume: Acme Inc., Initech")
        let fallback = ApplyScripts.Experience(companies: ["A", "B"], from_resume: false, note: "No resume picked for this job")
        #expect(fallback.summary == "All your Profile jobs (No resume picked for this job)")

        let plan = try JSONDecoder().decode(FieldPlan.self, from: Data(#"""
            {"key":"k","label":"Company","kind":"text","required":true,"status":"resolved","note":null,
             "source":"work experience 1 (Acme Inc.)"}
            """#.utf8))
        #expect(plan.source == "work experience 1 (Acme Inc.)")
    }

    @Test func decodesJobManagersPageAnswer() throws {
        let json = #"{"job":{"id":7,"company":"Xcimer","title":"Engineer","url":"https://jobs.lever.co/x/1"},"resume":{"id":3,"name":"Resume.pdf"},"cover_letter":null}"#
        let info = try JSONDecoder().decode(PageInfo.self, from: Data(json.utf8))
        #expect(info.job?.company == "Xcimer")
        #expect(info.resume == PageDocument(id: 3, name: "Resume.pdf"))
        #expect(info.cover_letter == nil)
        let none = try JSONDecoder().decode(PageInfo.self, from: Data(#"{"job":null,"resume":null,"cover_letter":null}"#.utf8))
        #expect(none.job == nil)
    }

    @Test func reportCountsFilledAttachedAndWhatNeedsYou() {
        let plans = [
            FieldPlan(key: "resume", label: "Resume/CV", kind: "file", required: true, status: "resolved", note: nil),
            FieldPlan(key: "email", label: "Email", kind: "text", required: true, status: "resolved", note: nil),
            FieldPlan(key: "name", label: "Full name", kind: "text", required: true, status: "resolved", note: nil),
            FieldPlan(key: "school", label: "School", kind: "combobox", required: true, status: "resolved", note: nil),
            FieldPlan(key: "why", label: "Why us?", kind: "textarea", required: true, status: "unknown", note: "Write this answer"),
            FieldPlan(key: "twitter", label: "Twitter", kind: "text", required: false, status: "skipped", note: nil),
        ]
        let results = [
            FillResult(key: "resume", status: "filled", note: nil),
            FillResult(key: "email", status: "filled", note: nil),
            FillResult(key: "name", status: "filled", note: nil),
            FillResult(key: "school", status: "check", note: "Typed “Michigan”; pick it from the list"),
        ]
        let report = AutofillReport.from(plans: plans, results: results)
        #expect(report.filled == 2)
        #expect(report.attached == ["Resume/CV"])
        #expect(report.needsYou == ["Why us? — Write this answer"])
        #expect(report.check.count == 1)
        #expect(report.summary == "Filled 2 fields · attached Resume/CV · 1 needs you · 1 to check")
        #expect(AutofillReport(problem: "No form").summary == "No form")
    }

    @Test func documentsTravelAsBase64WithTheirType() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "assist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resume = folder.appending(path: "Resume.pdf")
        try Data("%PDF-1.4".utf8).write(to: resume)
        let info = PageInfo(job: .init(id: 1, company: "A", title: "B", url: nil), resume: .init(id: 2, name: "Resume.pdf"), cover_letter: nil)
        let match = PageMatch(tab: BrowserTabRef(url: URL(string: "https://x.com")!, bundleID: "", browser: "Chrome"),
                              info: info, resumeFile: resume, coverLetterFile: nil)
        let files = PageForm.files(for: match)
        let entry = try #require(files["resume"] as? [String: String])
        #expect(entry["name"] == "Resume.pdf")
        #expect(entry["type"] == "application/pdf")
        #expect(entry["base64"].flatMap { Data(base64Encoded: $0) } == Data("%PDF-1.4".utf8))
        #expect(files["cover_letter"] == nil)
        #expect(PageForm.mimeType(URL(fileURLWithPath: "/a/b.docx")).hasSuffix("wordprocessingml.document"))
    }
}
