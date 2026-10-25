import Foundation
import Testing
@testable import JobsApp

private func url(_ s: String) -> URL { URL(string: s)! }

private func job(_ id: Int, _ company: String, status: String? = nil) throws -> TrackedJob {
    let event = status.map {
        #"{"status":"\#($0)","interview_round":null,"oa_score":null,"oa_submitted_at":null,"oa_deadline_at":null,"oa_link":null,"interview_held_at":null,"interview_link":null,"occurred_at":"2026-10-15T10:00:00.000Z"}"#
    } ?? "null"
    let json = #"{"id":\#(id),"company":"\#(company)","title":"Engineer","url":null,"created_at":"2026-10-01T10:00:00.000Z","latest_event":\#(event),"pending_after":null}"#
    return TrackedJob(try JSONDecoder().decode(JobRecord.self, from: Data(json.utf8)))
}

@Suite struct PageLinksTests {
    @Test func samePageKeysMatchHoweverItWasReached() {
        let key = PageLinks.key(url("https://boards.greenhouse.io/embed/job_app?for=acme&token=123"))
        #expect(PageLinks.key(url("https://www.boards.greenhouse.io/embed/job_app/?token=123&for=acme&utm_source=x#app")) == key)
        #expect(PageLinks.key(url("https://boards.greenhouse.io/embed/job_app?for=acme&token=999")) != key)
        // Trailing /apply is the same posting; tracking parameters don't matter.
        #expect(PageLinks.key(url("https://careers.acme.com/jobs/swe-intern/apply?ref=linkedin"))
                == PageLinks.key(url("https://careers.acme.com/jobs/swe-intern")))
    }

    @Test func jobPagesAreRecognizedByRules() {
        #expect(PageLinks.looksLikeJobPage(url("https://acme.wd5.myworkdayjobs.com/en-US/External/job/123"), title: ""))
        #expect(PageLinks.looksLikeJobPage(url("https://www.acme.com/careers/software-intern"), title: ""))
        #expect(PageLinks.looksLikeJobPage(url("https://acme.com/x/42"), title: "Apply for Software Intern at Acme"))
        #expect(!PageLinks.looksLikeJobPage(url("https://mail.google.com/mail/u/0"), title: "Inbox (3)"))
        #expect(!PageLinks.looksLikeJobPage(url("https://github.com/acme/repo"), title: "acme/repo"))
    }

    @Test func candidatesPutTheCompanyOnThePageFirst() throws {
        let jobs = [try job(1, "Globex"), try job(2, "Acme Robotics"), try job(3, "Initech", status: "rejected"), try job(4, "Hooli", status: "applied")]
        let ranked = PageLinks.candidates(jobs, url: url("https://acmerobotics.com/careers/42"), title: "Software Intern")
        #expect(ranked.map(\.id) == [2, 1, 4])
        // Finished applications aren't offered.
        #expect(!ranked.contains { $0.id == 3 })
    }

    @Test func linkedPagesSurviveSaving() throws {
        let linked = LinkedPage(info: PageInfo(job: .init(id: 7, company: "Acme", title: "Intern", url: nil),
                                               resume: .init(id: 3, name: "R.pdf"), cover_letter: nil),
                                sourceURL: url("https://jobs.lever.co/acme/1"))
        let data = try JSONEncoder().encode(["k": linked])
        #expect(try JSONDecoder().decode([String: LinkedPage].self, from: data)["k"] == linked)
    }
}
