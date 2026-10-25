import Foundation
import NotchKit

// MARK: - JobManager API shapes (/api/apply/*)

struct PageInfo: Decodable, Equatable {
    struct Job: Decodable, Equatable {
        let id: Int
        let company: String
        let title: String
        let url: String?
    }
    let job: Job?
    let resume: PageDocument?
    let cover_letter: PageDocument?
}

struct PageDocument: Decodable, Equatable {
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
    let info: PageInfo
    var resumeFile: URL?
    var coverLetterFile: URL?

    var job: PageInfo.Job { info.job! }
}

/// Which page a match was made for (the full tab isn't Equatable-friendly to keep around).
struct BrowserTabRef: Equatable {
    let url: URL
    let bundleID: String
    let browser: String
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
