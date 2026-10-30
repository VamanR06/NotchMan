import Foundation
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

    @Test func pathsWithQueriesKeepTheirQuestionMark() {
        let base = URL(string: "https://jobs.vamanr.com")!
        #expect(JobManagerClient.url(base, "api/documents?kind=resume").absoluteString == "https://jobs.vamanr.com/api/documents?kind=resume")
        #expect(JobManagerClient.url(base, "api/jobs/4").absoluteString == "https://jobs.vamanr.com/api/jobs/4")
    }
}
