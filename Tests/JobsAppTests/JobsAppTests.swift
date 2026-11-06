import Foundation
import Testing
@testable import JobsApp

/// Shaped like JobManager's GET /api/jobs response.
private let json = """
[
  {"id": 1, "company": "Acme", "title": "SWE Intern", "url": null, "notes": "", "resume_id": null,
   "cover_letter_id": null, "created_at": "2026-10-01T10:00:00.000Z",
   "latest_event": {"id": 11, "job_id": 1, "status": "oa", "interview_round": null, "oa_score": null,
     "oa_sent_at": "2026-10-18T10:00:00.000Z", "oa_submitted_at": null, "oa_deadline_at": "2026-10-21T04:00:00.000Z",
     "oa_link": "https://hackerrank.com/x", "interview_offered_at": null, "interview_held_at": null,
     "interview_link": null, "pre_notes": "", "post_notes": "", "occurred_at": "2026-10-18T10:00:00.000Z",
     "created_at": "2026-10-18T10:00:00.000Z"},
   "pending_after": null},
  {"id": 2, "company": "Globex", "title": "Robotics Engineer", "url": null, "notes": "", "resume_id": null,
   "cover_letter_id": null, "created_at": "2026-10-02T10:00:00.000Z",
   "latest_event": {"id": 12, "job_id": 2, "status": "interview", "interview_round": 2, "oa_score": null,
     "oa_sent_at": null, "oa_submitted_at": null, "oa_deadline_at": null, "oa_link": null,
     "interview_offered_at": "2026-10-15T10:00:00.000Z", "interview_held_at": "2026-10-20T19:00:00.000Z",
     "interview_link": "https://zoom.us/j/1", "pre_notes": "", "post_notes": "",
     "occurred_at": "2026-10-15T10:00:00.000Z", "created_at": "2026-10-15T10:00:00.000Z"},
   "pending_after": null},
  {"id": 3, "company": "Initech", "title": "Backend", "url": null, "notes": "", "resume_id": null,
   "cover_letter_id": null, "created_at": "2026-10-03T10:00:00.000Z",
   "latest_event": {"id": 13, "job_id": 3, "status": "pending", "interview_round": null, "oa_score": null,
     "oa_sent_at": null, "oa_submitted_at": null, "oa_deadline_at": null, "oa_link": null,
     "interview_offered_at": null, "interview_held_at": null, "interview_link": null, "pre_notes": "",
     "post_notes": "", "occurred_at": "2026-10-17T10:00:00.000Z", "created_at": "2026-10-17T10:00:00.000Z"},
   "pending_after": {"id": 9, "job_id": 3, "status": "interview", "interview_round": 1, "oa_score": null,
     "oa_sent_at": null, "oa_submitted_at": null, "oa_deadline_at": null, "oa_link": null,
     "interview_offered_at": null, "interview_held_at": null, "interview_link": null, "pre_notes": "",
     "post_notes": "", "occurred_at": "2026-10-10T10:00:00.000Z", "created_at": "2026-10-10T10:00:00.000Z"}},
  {"id": 4, "company": "Hooli", "title": "ML Intern", "url": null, "notes": "", "resume_id": null,
   "cover_letter_id": null, "created_at": "2026-10-04T10:00:00.000Z", "latest_event": null, "pending_after": null},
  {"id": 5, "company": "Umbrella", "title": "QA", "url": null, "notes": "", "resume_id": null,
   "cover_letter_id": null, "created_at": "2026-10-05T10:00:00.000Z",
   "latest_event": {"id": 15, "job_id": 5, "status": "rejected", "interview_round": null, "oa_score": null,
     "oa_sent_at": null, "oa_submitted_at": null, "oa_deadline_at": null, "oa_link": null,
     "interview_offered_at": null, "interview_held_at": null, "interview_link": null, "pre_notes": "",
     "post_notes": "", "occurred_at": "2026-10-06T10:00:00.000Z", "created_at": "2026-10-06T10:00:00.000Z"},
   "pending_after": null}
]
"""

private func jobs() throws -> [TrackedJob] {
    try JSONDecoder().decode([JobRecord].self, from: Data(json.utf8)).map(TrackedJob.init)
}

/// 2026-10-20 12:00 UTC.
private let now = Date(timeIntervalSince1970: 1_792_497_600)

@Suite struct JobBoardTests {
    @Test func decodesJobManagerResponse() throws {
        let all = try jobs()
        #expect(all.map(\.status) == [.oa, .interview, .pending, .toApply, .rejected])
        #expect(all[1].badge == "R2")
        #expect(all[2].pendingAfter == .interview)
        #expect(all[0].oaLink?.host() == "hackerrank.com")
    }

    @Test func comingUpHasDeadlinesAndInterviewsInOrder() throws {
        let board = JobBoard(jobs: try jobs(), now: now)
        #expect(board.comingUp.map(\.job.company) == ["Globex", "Acme"])
        #expect(board.comingUp.map(\.kind) == [.interview, .oaDeadline])
    }

    @Test func inProgressExcludesScheduledJobs() throws {
        let board = JobBoard(jobs: try jobs(), now: now)
        #expect(board.inProgress.map(\.company) == ["Initech"])
        #expect(board.toApply.map(\.company) == ["Hooli"])
        #expect(board.counts[.rejected] == 1)
    }

    @Test func urgentPicksTheInterviewToday() throws {
        let board = JobBoard(jobs: try jobs(), now: now)
        #expect(board.urgent(now: now)?.job.company == "Globex")
    }

    @Test func pastInterviewsDropOut() throws {
        let later = now.addingTimeInterval(3 * 24 * 3600)
        let board = JobBoard(jobs: try jobs(), now: later)
        #expect(!board.comingUp.contains { $0.kind == .interview })
        #expect(board.inProgress.map(\.company).contains("Globex"))
    }
}

@MainActor @Suite struct LoginResponseTests {
    private let base = URL(string: "https://jobs.example.com")!

    private func response(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: base, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    @Test func extractsSessionCookie() throws {
        let cookie = try JobManagerClient.sessionCookie(
            from: response(303, ["Location": "/", "Set-Cookie": "jm_session=abc.def; Path=/; HttpOnly; Secure; SameSite=lax"]),
            base: base)
        #expect(cookie == "abc.def")
    }

    @Test func wrongPasswordAndLockout() {
        #expect(throws: JobManagerClient.ClientError.self) {
            try JobManagerClient.sessionCookie(from: response(303, ["Location": "/login?error=invalid&next=%2F"]), base: base)
        }
        do {
            _ = try JobManagerClient.sessionCookie(from: response(303, ["Location": "/login?error=locked&next=%2F"]), base: base)
            Issue.record("expected lockout")
        } catch JobManagerClient.ClientError.lockedOut {
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func rejectsPlainHTTPExceptLocalhost() throws {
        #expect(throws: JobManagerClient.ClientError.self) { try JobManagerClient.validate("http://jobs.example.com") }
        #expect(try JobManagerClient.validate("http://localhost:3000").port == 3000)
        #expect(try JobManagerClient.validate("https://jobs.example.com/").absoluteString == "https://jobs.example.com")
    }
}

@Suite struct JobFilterTests {
    @Test func filtersByStatus() throws {
        let board = JobBoard(jobs: try jobs(), now: now)
        #expect(board.jobs(for: .status(.rejected), matching: "").map(\.company) == ["Umbrella"])
        #expect(board.count(.status(.oa)) == 1)
        #expect(board.count(.all) == 5)
        #expect(board.count(.active) == 4)
    }

    @Test func searchMatchesCompanyOrTitle() throws {
        let board = JobBoard(jobs: try jobs(), now: now)
        #expect(board.jobs(for: .all, matching: "robotics").map(\.company) == ["Globex"])
        #expect(board.jobs(for: .all, matching: " acme ").map(\.company) == ["Acme"])
        #expect(board.jobs(for: .status(.rejected), matching: "acme").isEmpty)
    }

    @Test func allIsMostRecentFirst() throws {
        let board = JobBoard(jobs: try jobs(), now: now)
        #expect(board.all.first?.company == "Acme")
    }
}

@Suite struct PromptTemplateTests {
    private func hooli() throws -> TrackedJob {
        try #require(try jobs().first { $0.company == "Hooli" })
    }

    @Test func fillsPlaceholders() throws {
        let template = PromptTemplate(name: "t", text: "{title} @ {company} ({location}) {url}\n{posting}")
        let posting = JobPosting(description: "Build ML things.", location: "Ann Arbor, MI")
        let text = template.render(job: try hooli(), url: "https://jobs.example/1", posting: posting)
        #expect(text == "ML Intern @ Hooli (Ann Arbor, MI) https://jobs.example/1\nBuild ML things.")
    }

    @Test func fallsBackWhenNoPostingSaved() throws {
        let template = PromptTemplate(name: "t", text: "{posting}|{location}")
        #expect(template.render(job: try hooli(), url: "https://x.example", posting: nil)
                == "(No description saved — see https://x.example)|location not listed")
        #expect(template.render(job: try hooli(), url: nil, posting: nil) == "(No description saved.)|location not listed")
    }

    @Test func truncatesLongPostings() throws {
        let long = JobPosting(description: String(repeating: "a", count: PromptTemplate.maxPostingLength + 500), location: nil)
        let text = PromptTemplate(name: "t", text: "{posting}").render(job: try hooli(), url: nil, posting: long)
        #expect(text.hasSuffix("[…truncated]"))
        #expect(text.count < PromptTemplate.maxPostingLength + 50)
    }

    @Test func defaultsUseThePosting() {
        #expect(PromptTemplate.defaults.count == 3)
        #expect(PromptTemplate.defaults.allSatisfy { $0.text.contains("{posting}") })
    }

    @Test func decodesPostingOrNull() throws {
        let json = ##"{"job_id": 4, "title": null, "company": null, "location": "Remote", "description_md": "# Role", "source": "parsed", "fetch_status": "ok", "fetched_at": "2026-10-04T10:00:00.000Z"}"##
        let posting = try JSONDecoder().decode(JobPosting?.self, from: Data(json.utf8))
        #expect(posting?.description == "# Role" && posting?.location == "Remote")
        #expect(try JSONDecoder().decode(JobPosting?.self, from: Data("null".utf8)) == nil)
    }
}

@Suite struct ProjectLinkTests {
    @Test func acceptsChatGPTLinksOnly() {
        #expect(PromptTemplate.isChatGPTLink("https://chatgpt.com/g/g-p-67c8abc-job-search/project"))
        #expect(!PromptTemplate.isChatGPTLink("http://chatgpt.com/g/g-p-1/project"))
        #expect(!PromptTemplate.isChatGPTLink("https://evil.example/chatgpt.com"))
    }

    @Test func oldSavedTemplatesStillDecode() throws {
        let json = #"[{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "Old", "text": "{title}"}]"#
        let templates = try JSONDecoder().decode([PromptTemplate].self, from: Data(json.utf8))
        #expect(templates.first?.projectURL == nil)
    }
}
