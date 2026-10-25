import Foundation

/// How the page in the browser got tied to a job.
enum PageMatchSource: String, Codable, Equatable {
    /// JobManager recognizes the page (the saved posting, its application form, or the same ATS posting).
    case tracked
    /// The same tab showed the job a moment ago and moved on (Apply, an embedded form, the form's next step).
    case followed
    /// Tied to the job earlier (followed, opened from the card, or picked), remembered for next time.
    case linked
    /// Picked from the list just now.
    case picked
}

/// A page tied to a job, remembered across launches.
struct LinkedPage: Codable, Equatable {
    let info: PageInfo
    /// A page JobManager itself matched to the job, to refresh its documents from.
    let sourceURL: URL?
}

/// Plain rules for tying pages to jobs when the address alone doesn't say.
enum PageLinks {
    /// The same page however it was reached: no scheme, "www.", fragment, tracking parameters, trailing slash,
    /// or trailing /apply · /application; only parameters that identify a posting are kept.
    static func key(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        let host = (components.host ?? "").lowercased().replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        path = path.replacingOccurrences(of: #"/(apply|application)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let identity: Set<String> = ["token", "for", "gh_jid", "ashby_jid", "jk", "vjk", "currentjobid", "jobid", "job_id", "id", "req", "requisitionid"]
        let kept = (components.queryItems ?? [])
            .filter { identity.contains($0.name.lowercased()) && !($0.value ?? "").isEmpty }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
            .map { "\($0.name.lowercased())=\($0.value ?? "")" }
        return host + path + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&"))
    }

    /// Application-tracking sites: a page there is a job page.
    static let atsHosts = ["greenhouse.io", "lever.co", "ashbyhq.com", "myworkdayjobs.com", "myworkdaysite.com", "smartrecruiters.com",
                           "icims.com", "workable.com", "oraclecloud.com", "taleo.net", "successfactors.com", "jobvite.com",
                           "bamboohr.com", "recruitee.com", "breezy.hr", "jazzhr.com", "applytojob.com", "rippling.com",
                           "dover.com", "gem.com", "wellfound.com", "linkedin.com", "indeed.com", "handshake.com", "joinhandshake.com"]

    /// Whether a page is plausibly a job posting or application: an ATS site, or job words in its address or
    /// title. Decides when following a tab or offering "Link this page" makes sense (never for Gmail, docs…).
    static func looksLikeJobPage(_ url: URL, title: String) -> Bool {
        let host = (url.host() ?? "").lowercased()
        if atsHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        let text = (url.path + " " + (url.query ?? "") + " " + title).lowercased()
        return text.range(of: #"\b(apply|application|careers?|jobs?|positions?|openings?|requisitions?|vacanc(y|ies)|internships?|hiring)\b"#,
                          options: .regularExpression) != nil
    }

    /// Jobs to offer for linking a page, best guess first: ones still in play, with those whose company shows up
    /// in the page's address or title on top. The person picks; nothing is linked without them.
    static func candidates(_ jobs: [TrackedJob], url: URL, title: String) -> [TrackedJob] {
        let open = jobs.filter { ![.rejected, .accepted].contains($0.status) }
        let haystack = ((url.host() ?? "") + " " + url.path + " " + title).lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        let squashed = haystack.replacingOccurrences(of: " ", with: "")
        func mentions(_ job: TrackedJob) -> Bool {
            let name = job.company.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
            return name.count >= 3 && squashed.contains(name)
        }
        let rank: (TrackedJob) -> Int = { job in
            (mentions(job) ? 0 : 2) + (job.status == .toApply ? 0 : 1)
        }
        return open.enumerated().sorted { a, b in
            (rank(a.element), a.offset) < (rank(b.element), b.offset)
        }.map(\.element)
    }

    /// How long a tab keeps the job it showed when it moves to an unrecognized page.
    static let followWindow: TimeInterval = 45 * 60
}
