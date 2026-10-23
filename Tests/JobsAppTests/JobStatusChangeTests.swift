import Foundation
import Testing
@testable import JobsApp

private func job(id: Int, status: String?, round: Int? = nil) throws -> TrackedJob {
    let event = status.map { status in
        """
        {"status": "\(status)", "interview_round": \(round.map(String.init) ?? "null"), "oa_score": null,
         "oa_submitted_at": null, "oa_deadline_at": null, "oa_link": null, "interview_held_at": null,
         "interview_link": null, "occurred_at": "2026-10-15T10:00:00.000Z"}
        """
    } ?? "null"
    let json = """
    {"id": \(id), "company": "Acme", "title": "SWE", "url": null, "created_at": "2026-10-01T10:00:00.000Z",
     "latest_event": \(event), "pending_after": null}
    """
    return TrackedJob(try JSONDecoder().decode(JobRecord.self, from: Data(json.utf8)))
}

@MainActor @Suite struct JobStatusChangeTests {
    @Test func statusEventBodyNamesJobAndStatus() throws {
        let body = JobManagerClient.statusEventBody(.applied, for: try job(id: 7, status: nil))
        #expect(body["job_id"] as? Int == 7)
        #expect(body["status"] as? String == "applied")
        #expect(body["interview_round"] == nil)
    }

    @Test func interviewStartsAtRoundOneOrAdvancesTheRound() throws {
        let atOA = try job(id: 1, status: "oa")
        #expect(JobManagerClient.statusEventBody(.interview, for: atOA)["interview_round"] as? Int == 1)
        let roundTwo = try job(id: 2, status: "interview", round: 2)
        #expect(JobManagerClient.statusEventBody(.interview, for: roundTwo)["interview_round"] as? Int == 3)
    }
}
