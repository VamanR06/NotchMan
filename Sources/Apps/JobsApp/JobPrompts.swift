import Foundation

/// A ChatGPT prompt for a job, with placeholders filled from the job and its saved posting:
/// {title} {company} {url} {location} {posting}.
struct PromptTemplate: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var text: String
    /// ChatGPT project to start the chat in; nil/empty uses the default project from settings.
    var projectURL: String?

    /// Whether `string` looks like a ChatGPT page link (projects live at chatgpt.com/g/g-p-…/project).
    static func isChatGPTLink(_ string: String) -> Bool {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespaces)),
              url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
    }

    static let placeholders = ["{title}", "{company}", "{url}", "{location}", "{posting}"]

    static let defaults: [PromptTemplate] = [
        PromptTemplate(name: "Fit & tailoring", text: """
            I'm applying to {title} at {company} ({url}).

            Job description:
            {posting}

            Assess how well I fit this role, list the key skills and keywords I should emphasize on my resume, \
            and suggest 3 tailored resume bullet points.
            """),
        PromptTemplate(name: "Cover letter", text: """
            Write a concise, specific cover letter for the {title} role at {company} ({location}).

            Job description:
            {posting}
            """),
        PromptTemplate(name: "Interview prep", text: """
            Research {company} and the {title} role ({url}). Summarize what the company does, likely interview \
            topics for this role, and good questions for me to ask.

            Job description:
            {posting}
            """),
    ]

    /// Long postings are trimmed so the prompt stays a reasonable size.
    static let maxPostingLength = 12_000

    func render(job: TrackedJob, url: String?, posting: JobPosting?) -> String {
        var description = posting?.description.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if description.isEmpty {
            description = url.map { "(No description saved — see \($0))" } ?? "(No description saved.)"
        } else if description.count > Self.maxPostingLength {
            description = String(description.prefix(Self.maxPostingLength)) + "\n[…truncated]"
        }
        return text
            .replacingOccurrences(of: "{title}", with: job.title)
            .replacingOccurrences(of: "{company}", with: job.company)
            .replacingOccurrences(of: "{url}", with: url ?? "no link")
            .replacingOccurrences(of: "{location}", with: posting?.location ?? "location not listed")
            .replacingOccurrences(of: "{posting}", with: description)
    }
}

/// JobManager's saved snapshot of a posting (GET /api/jobs/<id>/posting).
struct JobPosting: Decodable {
    let description: String
    let location: String?

    enum CodingKeys: String, CodingKey {
        case description = "description_md"
        case location
    }
}
