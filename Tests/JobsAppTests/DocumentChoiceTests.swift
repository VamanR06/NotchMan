import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JobsApp

@MainActor @Suite struct DocumentChoiceTests {
    /// Shaped like JobManager's GET /api/documents?kind=resume.
    private let json = """
    [
      {"id": 9, "kind": "resume", "name": "Vaman_Resume_Palantir", "file_path": "documents/9.pdf", "archived": 0,
       "generated": 0, "source_job_id": null, "thread_id": null, "version": 2, "content_sha256": null,
       "uploaded_at": "2026-10-29T10:00:00.000Z",
       "used_by": [{"id": 4, "company": "Palantir", "title": "SWE Intern"}, {"id": 5, "company": "Anduril", "title": "Intern"}]},
      {"id": 3, "kind": "resume", "name": "Old Resume.pdf", "file_path": "documents/3.pdf", "archived": 1,
       "generated": 0, "source_job_id": null, "thread_id": null, "version": 1, "content_sha256": null,
       "uploaded_at": "2026-09-01T10:00:00.000Z", "used_by": []}
    ]
    """

    @Test func decodesJobManagersDocumentList() throws {
        let documents = try JSONDecoder().decode([JobDocument].self, from: Data(json.utf8))
        #expect(documents.map(\.id) == [9, 3])
        #expect(!documents[0].isArchived && documents[1].isArchived)
        // Names get their extension for uploads; ones that have it keep it.
        #expect(documents[0].fileName == "Vaman_Resume_Palantir.pdf")
        #expect(documents[1].fileName == "Old Resume.pdf")
        #expect(documents[0].pageDocument == PageDocument(id: 9, name: "Vaman_Resume_Palantir.pdf"))
    }

    @Test func menuTitlesShowVersionAndWhereItsUsed() throws {
        let documents = try JSONDecoder().decode([JobDocument].self, from: Data(json.utf8))
        #expect(documents[0].menuTitle == "Vaman_Resume_Palantir (v2) · Palantir +1")
        #expect(documents[1].menuTitle == "Old Resume.pdf")
    }

    @Test func sideResumeIsYourPickElseTheNewest() throws {
        let documents = try JSONDecoder().decode([JobDocument].self, from: Data(json.utf8))
        #expect(JobsApp.quickResumeChoice(saved: nil, from: documents)?.id == 9, "newest that isn't archived")
        #expect(JobsApp.quickResumeChoice(saved: 3, from: documents)?.id == 3, "your pick, even archived")
        #expect(JobsApp.quickResumeChoice(saved: 42, from: documents)?.id == 9, "a deleted pick falls back")
        #expect(JobsApp.quickResumeChoice(saved: nil, from: [documents[1]])?.id == 3, "only archived ones: still one")
        #expect(JobsApp.quickResumeChoice(saved: nil, from: []) == nil)
    }

    /// Renders the side column's resume picker into build/dev for eyeballing.
    @Test func rendersQuickResume() throws {
        let documents = try JSONDecoder().decode([JobDocument].self, from: Data(json.utf8))
        let file = FileManager.default.temporaryDirectory.appending(path: "Resume_SWE_Robotics_v3.pdf")
        try Data("%PDF-1.4".utf8).write(to: file)
        let app = JobsApp()
        app.useQuickResumeForTesting(documents[0], file: file, choices: documents)
        let view = VStack(alignment: .leading, spacing: 4) {
            Text("Applications").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            Text("12").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
            Text("in progress").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 4)
            QuickResume(app: app)
        }
            .frame(width: 120, height: 150, alignment: .topLeading)
            .padding(14)
            .background(.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let tiff = try #require(renderer.nsImage?.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../build/dev").standardizedFileURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appending(path: "quick-resume.png"))
    }

    @Test func pathsWithQueriesKeepTheirQuestionMark() {
        let base = URL(string: "https://jobs.example.com")!
        #expect(JobManagerClient.url(base, "api/documents?kind=resume").absoluteString == "https://jobs.example.com/api/documents?kind=resume")
        #expect(JobManagerClient.url(base, "api/jobs/4").absoluteString == "https://jobs.example.com/api/jobs/4")
    }
}
