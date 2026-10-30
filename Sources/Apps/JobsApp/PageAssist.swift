import Foundation
import NotchKit

// MARK: - JobManager API shapes (/api/apply/*)

struct PageInfo: Codable, Equatable {
    struct Job: Codable, Equatable {
        let id: Int
        let company: String
        let title: String
        let url: String?
    }
    let job: Job?
    var resume: PageDocument?
    var cover_letter: PageDocument?
}

/// Resume or cover letter, as JobManager's document lists name them.
enum DocumentKind: String {
    case resume, cover_letter

    var label: String { self == .resume ? "Resume" : "Cover letter" }
}

/// A resume or cover letter in JobManager (GET /api/documents?kind=…).
struct JobDocument: Decodable, Identifiable, Equatable {
    struct Usage: Decodable, Equatable {
        let id: Int
        let company: String
        let title: String
    }

    let id: Int
    let name: String
    let file_path: String
    let archived: Int
    let version: Int
    let uploaded_at: String
    let used_by: [Usage]

    var isArchived: Bool { archived == 1 }

    /// The name with its extension, as an upload should show it (JobManager's names may omit it).
    var fileName: String {
        (name as NSString).pathExtension.isEmpty ? name + "." + (file_path as NSString).pathExtension : name
    }

    var pageDocument: PageDocument { PageDocument(id: id, name: fileName) }

    /// How it reads in the menu: the name, its version when there are several, and where else it's used.
    var menuTitle: String {
        var title = name + (version > 1 ? " (v\(version))" : "")
        if let first = used_by.first {
            title += " · \(first.company)" + (used_by.count > 1 ? " +\(used_by.count - 1)" : "")
        }
        return title
    }
}

struct PageDocument: Codable, Equatable {
    let id: Int
    let name: String
}

struct ApplyScripts: Decodable {
    let scan: String
    let fill: String
    let frames: String
}

/// One form field as JobManager's rules see it.
struct FieldPlan: Decodable, Equatable {
    let key: String
    let label: String
    let kind: String
    let required: Bool
    /// resolved (will be filled), unknown (needs you), skipped (optional, left blank), unsupported.
    let status: String
    let note: String?
}

/// What the in-page filler reports per field.
struct FillResult: Decodable, Equatable {
    let key: String
    /// filled, mismatch, check (typed into a search box: pick from the list), missing, skipped.
    let status: String
    let note: String?
}

/// The tracked job open in the browser, with its documents saved locally for dragging and attaching.
struct PageMatch: Equatable {
    let tab: BrowserTabRef
    var info: PageInfo
    var source: PageMatchSource = .tracked
    /// A page JobManager matched to this job (to refresh documents from, and to carry into links).
    var sourceURL: URL?
    var resumeFile: URL?
    var coverLetterFile: URL?

    var job: PageInfo.Job { info.job! }
}

/// Which page a match was made for.
struct BrowserTabRef: Equatable {
    let url: URL
    let bundleID: String
    let browser: String
    var tabID: String?
    var title: String = ""

    init(_ tab: BrowserTab) {
        url = tab.url
        bundleID = tab.bundleID
        browser = tab.browser
        tabID = tab.tabID
        title = tab.title
    }

    init(url: URL, bundleID: String, browser: String, tabID: String? = nil, title: String = "") {
        self.url = url
        self.bundleID = bundleID
        self.browser = browser
        self.tabID = tabID
        self.title = title
    }

    var browserTab: BrowserTab { BrowserTab(url: url, title: title, browser: browser, bundleID: bundleID, tabID: tabID) }
}

/// What autofill did, to show under the card.
struct AutofillReport: Equatable {
    var filled = 0
    /// Questions only you can answer (open questions, attestations, anything not in the Profile or answer bank).
    var needsYou: [String] = []
    /// Fields to look over: typed into a search box, or the page didn't take the value.
    var check: [String] = []
    var attached: [String] = []
    /// Something stopped it (no form, a sign-in wall, a CAPTCHA, JavaScript off…).
    var problem: String?
    /// An embedded form's own address, to open it directly.
    var embeddedForm: URL?

    var summary: String {
        if let problem { return problem }
        var parts = ["Filled \(filled) field\(filled == 1 ? "" : "s")"]
        if !attached.isEmpty { parts.append("attached \(attached.joined(separator: ", "))") }
        if !needsYou.isEmpty { parts.append("\(needsYou.count) need\(needsYou.count == 1 ? "s" : "") you") }
        if !check.isEmpty { parts.append("\(check.count) to check") }
        return parts.joined(separator: " · ")
    }

    /// Builds the report from JobManager's plan and the filler's results.
    static func from(plans: [FieldPlan], results: [FillResult]) -> AutofillReport {
        var report = AutofillReport()
        let labels = Dictionary(plans.map { ($0.key, $0.label) }, uniquingKeysWith: { a, _ in a })
        for result in results {
            let label = labels[result.key] ?? result.key
            switch result.status {
            case "filled":
                if plans.first(where: { $0.key == result.key })?.kind == "file" { report.attached.append(label) } else { report.filled += 1 }
            case "check", "mismatch", "missing":
                report.check.append(result.note.map { "\(label): \($0)" } ?? label)
            default:
                break
            }
        }
        report.needsYou = plans.filter { ($0.status == "unknown" || $0.status == "unsupported") }.map { plan in
            plan.note.map { "\(plan.label) — \($0)" } ?? plan.label
        }
        return report
    }
}

/// Running JobManager's scanner and filler in the browser's tab.
@MainActor
enum PageForm {
    struct Scan {
        /// The scanner's fields, passed to JobManager untouched.
        let fields: [[String: Any]]
        let blockers: [String]
        let hasApplyButton: Bool
    }

    enum FormError: LocalizedError {
        case unreadable
        var errorDescription: String? { "Couldn't read the page's form." }
    }

    static func scan(in tab: BrowserTab, script: String) async throws -> Scan {
        let output = try await tab.runJavaScript("JSON.stringify(\(script))")
        guard let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
            throw FormError.unreadable
        }
        return Scan(fields: json["fields"] as? [[String: Any]] ?? [],
                    blockers: json["blockers"] as? [String] ?? [],
                    hasApplyButton: json["hasApplyButton"] as? Bool ?? false)
    }

    static func embeddedForms(in tab: BrowserTab, script: String) async throws -> [URL] {
        let output = try await tab.runJavaScript("JSON.stringify(\(script))")
        let sources = (try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String]) ?? []
        return sources.compactMap(URL.init(string:)).filter { $0.scheme == "https" }
    }

    static func fill(in tab: BrowserTab, script: String, steps: Any, files: [String: Any]) async throws -> [FillResult] {
        guard let steps = (steps as? [Any]), !steps.isEmpty else { return [] }
        let stepsJSON = String(decoding: try JSONSerialization.data(withJSONObject: steps), as: UTF8.self)
        let filesJSON = String(decoding: try JSONSerialization.data(withJSONObject: files), as: UTF8.self)
        let output = try await tab.runJavaScript("JSON.stringify((\(script))(\(stepsJSON), \(filesJSON)))")
        guard let results = try? JSONDecoder().decode([FillResult].self, from: Data(output.utf8)) else { throw FormError.unreadable }
        return results
    }

    /// What the confirmation check found on the page.
    struct Confirmation: Decodable, Equatable {
        let confirmed: Bool
        let snippet: String?
    }

    /// JobManager's test for "the site took the application" (src/lib/apply/confirm.ts): the site's own
    /// confirmation text, and the application form gone from the page. A click on Submit isn't proof.
    static let confirmScript = #"""
    (() => {
      const text = (document.body && document.body.innerText) || "";
      const shown = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
      const formStillThere = Array.from(document.querySelectorAll("input[type=email], input[type=file], textarea")).some(shown);
      const ok = text.match(/thank(s| you) for (applying|your application|submitting|your interest in)|application (was |has been )?(successfully )?(submitted|received)|we('ve| have) received your application|your application (is|has been) (complete|submitted|received)/i);
      return { confirmed: !!ok && !formStillThere, snippet: ok ? text.slice(Math.max(0, ok.index - 60), ok.index + 180).replace(/\s+/g, " ").trim() : null };
    })()
    """#

    static func confirmation(in tab: BrowserTab) async throws -> Confirmation {
        let output = try await tab.runJavaScript("JSON.stringify(\(confirmScript))")
        guard let result = try? JSONDecoder().decode(Confirmation.self, from: Data(output.utf8)) else { throw FormError.unreadable }
        return result
    }

    /// The job's resume and cover letter as the filler wants them (base64), for upload fields.
    static func files(for match: PageMatch) -> [String: Any] {
        var files: [String: Any] = [:]
        for (key, url) in [("resume", match.resumeFile), ("cover_letter", match.coverLetterFile)] {
            guard let url, let data = try? Data(contentsOf: url) else { continue }
            files[key] = ["name": url.lastPathComponent, "type": mimeType(url), "base64": data.base64EncodedString()]
        }
        return files
    }

    static func mimeType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": "application/pdf"
        case "doc": "application/msword"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "txt": "text/plain"
        default: "application/octet-stream"
        }
    }
}
