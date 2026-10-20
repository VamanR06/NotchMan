import Foundation
import NotchKit
import SwiftUI

// MARK: - JobManager API shapes (GET /api/jobs)

struct JobRecord: Decodable {
    struct Event: Decodable {
        let status: String
        let interview_round: Int?
        let oa_score: String?
        let oa_submitted_at: String?
        let oa_deadline_at: String?
        let oa_link: String?
        let interview_held_at: String?
        let interview_link: String?
        let occurred_at: String
    }

    let id: Int
    let company: String
    let title: String
    let url: String?
    let created_at: String
    let latest_event: Event?
    let pending_after: Event?
}

// MARK: - App model

enum JobStatus: String, CaseIterable {
    case toApply = "to_apply", applied, oa, interview, pending, rejected, accepted

    var name: String {
        switch self {
        case .toApply: "To apply"
        case .applied: "Applied"
        case .oa: "OA"
        case .interview: "Interview"
        case .pending: "Pending"
        case .rejected: "Rejected"
        case .accepted: "Offer"
        }
    }

    var color: Color {
        switch self {
        case .toApply: .gray
        case .applied: .teal
        case .oa: .purple
        case .interview: .blue
        case .pending: .yellow
        case .rejected: .red
        case .accepted: .green
        }
    }
}

struct TrackedJob: Identifiable, Hashable {
    let id: Int
    let company: String
    let title: String
    /// The posting's URL, if the job has one.
    let url: String?
    let status: JobStatus
    let round: Int?
    /// For a pending job: the stage it's pending after.
    let pendingAfter: JobStatus?
    /// When the latest status was logged (or the job was added, if it has none).
    let statusDate: Date
    let oaDeadline: Date?
    let oaSubmitted: Bool
    let oaLink: URL?
    /// When the interview is/was held, for jobs at the interview stage.
    let interviewAt: Date?
    let interviewLink: URL?

    /// Short badge text, e.g. "OA", "R2", "Pending".
    var badge: String {
        switch status {
        case .interview: round.map { "R\($0)" } ?? "Interview"
        case .pending: "Pending"
        default: status.name
        }
    }

    init(_ record: JobRecord) {
        let event = record.latest_event
        let date = { (s: String?) in s.flatMap { DateParsing.parse($0)?.0 } }
        let link = { (s: String?) in s.flatMap { $0.isEmpty ? nil : URL(string: $0) } }

        id = record.id
        company = record.company
        title = record.title
        url = record.url.flatMap { $0.isEmpty ? nil : $0 }
        // A job with no status events is one still being considered.
        status = event.flatMap { JobStatus(rawValue: $0.status) } ?? .toApply
        round = event?.interview_round
        pendingAfter = record.pending_after.flatMap { JobStatus(rawValue: $0.status) }
        statusDate = date(event?.occurred_at) ?? date(record.created_at) ?? .distantPast
        oaDeadline = status == .oa ? date(event?.oa_deadline_at) : nil
        oaSubmitted = event?.oa_submitted_at?.isEmpty == false
        oaLink = link(event?.oa_link)
        interviewAt = status == .interview ? date(event?.interview_held_at) : nil
        interviewLink = link(event?.interview_link)
    }
}

/// A dated thing to act on: an OA deadline or an interview.
struct JobAction: Identifiable, Hashable {
    enum Kind: Hashable { case oaDeadline, interview }

    let job: TrackedJob
    let kind: Kind
    let date: Date

    var id: String { "\(job.id)-\(kind)" }
}

/// Which jobs the list shows.
enum JobFilter: Hashable {
    /// Coming up / in progress / to apply sections.
    case active
    case all
    case status(JobStatus)

    var name: String {
        switch self {
        case .active: "Active"
        case .all: "All"
        case .status(let status): status.name
        }
    }

    static let chips: [JobFilter] = [.active, .all] + [.applied, .oa, .interview, .pending, .toApply, .accepted, .rejected].map(JobFilter.status)
}

/// The dashboard derived from all jobs at a point in time.
struct JobBoard {
    /// Every job, most recently updated first.
    let all: [TrackedJob]
    let comingUp: [JobAction]
    let inProgress: [TrackedJob]
    let toApply: [TrackedJob]
    let counts: [JobStatus: Int]

    static let empty = JobBoard(jobs: [], now: .now)

    init(jobs: [TrackedJob], now: Date) {
        var counts: [JobStatus: Int] = [:]
        for job in jobs { counts[job.status, default: 0] += 1 }
        self.counts = counts
        all = jobs.sorted { $0.statusDate > $1.statusDate }

        var actions: [JobAction] = []
        for job in jobs {
            // Unsubmitted OAs with a deadline, including missed ones.
            if job.status == .oa, !job.oaSubmitted, let deadline = job.oaDeadline {
                actions.append(JobAction(job: job, kind: .oaDeadline, date: deadline))
            }
            // Interviews that haven't happened yet (or started within the last hour).
            if let at = job.interviewAt, at > now.addingTimeInterval(-3600) {
                actions.append(JobAction(job: job, kind: .interview, date: at))
            }
        }
        comingUp = actions.sorted { $0.date < $1.date }

        let scheduled = Set(actions.map(\.job.id))
        inProgress = jobs
            .filter { [.oa, .interview, .pending].contains($0.status) && !scheduled.contains($0.id) }
            .sorted { $0.statusDate > $1.statusDate }
        toApply = jobs.filter { $0.status == .toApply }.sorted { $0.statusDate > $1.statusDate }
    }

    /// Jobs for a non-sectioned filter, matching `query` against company and title.
    func jobs(for filter: JobFilter, matching query: String) -> [TrackedJob] {
        let base: [TrackedJob]
        switch filter {
        case .active, .all: base = all
        case .status(let status): base = all.filter { $0.status == status }
        }
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return base }
        return base.filter { $0.company.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query) }
    }

    func count(_ filter: JobFilter) -> Int {
        switch filter {
        case .active: comingUp.count + inProgress.count + toApply.count
        case .all: all.count
        case .status(let status): counts[status] ?? 0
        }
    }

    /// The next action soon enough to show beside the collapsed notch.
    func urgent(now: Date) -> JobAction? {
        comingUp.first { action in
            let until = action.date.timeIntervalSince(now)
            switch action.kind {
            case .interview: return until > -3600 && until <= 24 * 3600
            case .oaDeadline: return until > 0 && until <= 48 * 3600
            }
        }
    }
}

/// "in 5m", "in 3h", "in 2d", "2h ago".
func relativeTime(_ date: Date, now: Date) -> String {
    let seconds = date.timeIntervalSince(now)
    let minutes = Int((abs(seconds) / 60).rounded())
    let text = minutes < 60 ? "\(max(minutes, 1))m" : minutes < 48 * 60 ? "\(minutes / 60)h" : "\(minutes / 1440)d"
    return seconds >= 0 ? "in \(text)" : "\(text) ago"
}
