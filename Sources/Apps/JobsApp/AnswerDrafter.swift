import AppKit
import Foundation
import NotchKit
import PDFKit

// Drafting answers to a form's open-ended questions ("Why us?") with a model in Ollama on this Mac.
// Light on battery by design: nothing runs until you ask, one request covers every question on the page,
// the context window and output are capped, and the model unloads soon after (keep_alive).

/// One open-ended question from the last Autofill, and its draft.
struct DraftItem: Equatable, Identifiable, Sendable {
    let key: String
    let label: String
    let required: Bool
    var text = ""
    /// Typed into the page's field.
    var inserted = false

    var id: String { key }
}

/// How long Ollama keeps the model in memory after a draft (sent as `keep_alive`).
enum DraftKeepAlive: String, CaseIterable, Identifiable, Sendable {
    case none = "0s", minute = "60s", fiveMinutes = "5m"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Unload right away"
        case .minute: "1 minute"
        case .fiveMinutes: "5 minutes"
        }
    }
}

struct DraftSettings: Equatable, Sendable {
    var model = AnswerDrafter.defaultModel
    var keepAlive = DraftKeepAlive.minute
}

/// What the model knows about the job: who it's for, the posting, and the job's resume, trimmed to fit a small
/// context window.
struct DraftContext: Equatable, Sendable {
    static let maxPosting = 4_000
    static let maxResume = 3_500

    let company: String
    let title: String
    let location: String?
    let posting: String
    let resume: String?

    init(company: String, title: String, location: String?, posting: String?, resume: String?) {
        self.company = company
        self.title = title
        self.location = location.flatMap { $0.isEmpty ? nil : $0 }
        self.posting = Self.trimmed(posting ?? "", to: Self.maxPosting)
        self.resume = resume.map { Self.trimmed($0, to: Self.maxResume) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whitespace squeezed (PDF text is full of it), then cut at a word boundary.
    static func trimmed(_ text: String, to limit: Int) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
        var squeezed: [String] = []
        for line in lines where !(line.isEmpty && (squeezed.last?.isEmpty ?? true)) { squeezed.append(line) }
        let joined = squeezed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count > limit else { return joined }
        let cut = joined.prefix(limit)
        let end = cut.lastIndex(where: { $0 == " " || $0 == "\n" }) ?? cut.endIndex
        return String(cut[..<end]) + " …"
    }

    /// The text of a resume file: PDF through PDFKit; Word, RTF and plain text through the text system.
    static func resumeText(from url: URL) -> String? {
        let text: String?
        switch url.pathExtension.lowercased() {
        case "pdf": text = PDFDocument(url: url)?.string
        case "txt", "md": text = try? String(contentsOf: url, encoding: .utf8)
        default: text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

/// Talks to Ollama on this Mac (localhost:11434). Never starts it.
struct AnswerDrafter: Sendable {
    static let defaultModel = "gemma3:4b"
    static let contextTokens = 4_096
    static let tokensPerAnswer = 220
    static let maxTokens = 900

    var base = URL(string: "http://127.0.0.1:11434")!
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        return URLSession(configuration: config)
    }()

    enum Status: Equatable, Sendable {
        case notRunning, missingModel, ready
    }

    enum DraftError: LocalizedError, Equatable {
        case notRunning
        case missingModel(String)
        case ollama(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .notRunning: "Ollama isn't running. Open the Ollama app, then Draft again."
            case .missingModel(let model): "\(model) isn't downloaded. Run `ollama pull \(model)` in Terminal."
            case .ollama(let message): "Ollama: \(message)"
            case .empty: "The model didn't write anything. Try Redraft."
            }
        }
    }

    // MARK: Status

    /// Whether Ollama is up and has `model`, checked with one quick local request.
    func status(model: String) async -> Status {
        var request = URLRequest(url: base.appending(path: "api/tags"))
        request.timeoutInterval = 1.5
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return .notRunning }
        struct Tags: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }
        let names = (try? JSONDecoder().decode(Tags.self, from: data))?.models.map(\.name) ?? []
        return Self.has(model, in: names) ? .ready : .missingModel
    }

    /// "llama3.2" means "llama3.2:latest" to Ollama.
    static func has(_ model: String, in names: [String]) -> Bool {
        let wanted = model.contains(":") ? model : model + ":latest"
        return names.contains { $0 == model || $0 == wanted }
    }

    // MARK: Drafting

    /// Drafts every question in one request. Yields the answers so far, by question key, a few times a second
    /// while the model writes; the last value is complete. Cancelling the task stops Ollama generating.
    func draft(questions: [DraftItem], context: DraftContext, settings: DraftSettings) -> AsyncThrowingStream<[String: String], Error> {
        let session = session
        let url = base.appending(path: "api/chat")
        let withThink = Self.requestBody(questions: questions, context: context, settings: settings)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    do {
                        try await Self.stream(session: session, url: url, body: withThink, questions: questions,
                                              model: settings.model, into: continuation)
                    } catch DraftError.ollama(let message) where message.localizedCaseInsensitiveContains("think") {
                        // Older Ollama, or a model that refuses the flag: same request without it.
                        let plain = Self.requestBody(questions: questions, context: context, settings: settings, think: false)
                        try await Self.stream(session: session, url: url, body: plain, questions: questions,
                                              model: settings.model, into: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.friendly(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Chunk: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
        let done: Bool?
        let error: String?
    }

    private static func stream(session: URLSession, url: URL, body: Data, questions: [DraftItem], model: String,
                               into continuation: AsyncThrowingStream<[String: String], Error>.Continuation) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let message = (try? JSONDecoder().decode(Chunk.self, from: data))?.error ?? "HTTP \(status)"
            if status == 404 && message.contains("not found") { throw DraftError.missingModel(model) }
            throw DraftError.ollama(message)
        }
        var output = ""
        var lastYield = Date.distantPast
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(line.utf8)) else { continue }
            if let error = chunk.error { throw DraftError.ollama(error) }
            output += chunk.message?.content ?? ""
            // Redrawing the notch on every token costs more than the text is worth: a few times a second.
            if chunk.done == true || Date().timeIntervalSince(lastYield) > 0.15 {
                continuation.yield(answers(in: output, questions: questions))
                lastYield = Date()
            }
            if chunk.done == true { break }
        }
        let final = answers(in: output, questions: questions)
        if final.values.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { throw DraftError.empty }
        continuation.yield(final)
    }

    static func friendly(_ error: Error) -> Error {
        if let urlError = error as? URLError,
           [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet].contains(urlError.code) {
            return DraftError.notRunning
        }
        return error
    }

    // MARK: Request

    /// Question ids the model answers under: short and predictable, whatever the form's own keys look like.
    static func ids(_ questions: [DraftItem]) -> [String] { questions.indices.map { "q\($0 + 1)" } }

    static func requestBody(questions: [DraftItem], context: DraftContext, settings: DraftSettings, think: Bool = true,
                            system: String = prompt.text) -> Data {
        let ids = ids(questions)
        var body: [String: Any] = [
            "model": settings.model,
            "stream": true,
            "keep_alive": settings.keepAlive.rawValue,
            // Structured output: one string per question, so there's nothing to clean up or retry.
            "format": [
                "type": "object",
                "properties": Dictionary(uniqueKeysWithValues: ids.map { ($0, ["type": "string"]) }),
                "required": ids,
            ] as [String: Any],
            "options": [
                "num_ctx": contextTokens,
                "num_predict": min(maxTokens, tokensPerAnswer * questions.count + 40),
                "temperature": 0.6,
            ],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userPrompt(questions: questions, context: context)],
            ],
        ]
        // Reasoning models (qwen3, deepseek-r1) would otherwise think first: slower, and more battery.
        if think { body["think"] = false }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    static let defaultSystemPrompt = """
        You draft answers to open-ended questions on a job application, written as the applicant in the first \
        person. Make each answer specific to this company and role, using the job description. Use only facts \
        from the resume: never invent employers, projects, numbers, or skills. If an answer needs a detail the \
        resume doesn't give, leave a short [bracketed placeholder].

        Write the way a sharp student talks to a recruiter: plain, direct, concrete. Short sentences. Say what \
        I did and why it matters here, then stop.
        - Never use em dashes or en dashes. Use commas, periods, or "and" instead.
        - No semicolons, no colons before a list, no exclamation marks, no rhetorical questions.
        - Don't use these words or phrases: thrilled, excited to, passionate, passion, delve, leverage, \
        utilize, foster, spearhead, synergy, dynamic, cutting-edge, innovative, robust, seamless, tapestry, \
        testament, landscape, realm, journey, navigate, embark, resonate, align with, deeply, truly, \
        I am confident, I believe I would be a great fit, unique opportunity, make an impact, \
        drive meaningful change, at the intersection of, not only... but also, in today's world.
        - Don't open by restating the question or the company's mission, and don't end with a summary line.
        - No headings and no lists.
        Aim for 80 to 150 words per answer, or fewer when the question asks for less. Answer every question id \
        in the JSON.
        """

    /// The instructions above, as you've edited them in Settings → Prompts.
    static let prompt = EditablePrompt(
        id: "jobs.answerDrafts", group: "Jobs", title: "Answer drafts",
        detail: "How the Ollama model writes answers to a form's open questions. The job, its description, your resume and the questions are sent after it. Dashes are turned into commas whatever this says.",
        defaultText: defaultSystemPrompt)

    /// Small models use dashes anyway: turn them into the punctuation a person would type.
    static func humanized(_ text: String) -> String {
        // Ranges ("2023 – 2024", "3–5") keep a plain hyphen.
        var s = text.replacingOccurrences(of: #"(\d)\s*[–—]\s*(\d)"#, with: "$1-$2", options: .regularExpression)
        // "word — word", "word—word", "word – word" read as a pause: a comma.
        for dash in ["\u{2014}", "\u{2013}"] {
            s = s.replacingOccurrences(of: " \(dash) ", with: ", ")
            s = s.replacingOccurrences(of: "\(dash) ", with: ", ")
            s = s.replacingOccurrences(of: " \(dash)", with: ",")
            s = s.replacingOccurrences(of: dash, with: dash == "\u{2013}" ? "-" : ", ")
        }
        // A spaced hyphen used as a dash.
        s = s.replacingOccurrences(of: " - ", with: ", ")
        s = s.replacingOccurrences(of: ",,", with: ",").replacingOccurrences(of: ", ,", with: ",")
        s = s.replacingOccurrences(of: ",.", with: ".")
        return s
    }

    static func userPrompt(questions: [DraftItem], context: DraftContext) -> String {
        var parts = ["Role: \(context.title) at \(context.company)" + (context.location.map { " (\($0))" } ?? "")]
        parts.append("Job description:\n" + (context.posting.isEmpty ? "(none saved; go by the role and company)" : context.posting))
        parts.append("My resume:\n" + (context.resume ?? "(no resume attached; keep to what the role suggests and use placeholders for my specifics)"))
        let list = zip(ids(questions), questions).map { id, q in "\(id): \(q.label)" + (q.required ? "" : " (optional)") }
        parts.append("Questions:\n" + list.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }

    // MARK: Reading the answers as they stream

    /// The answers in the model's JSON so far, by question key, read leniently: a string still being written
    /// counts up to where it's got to.
    static func answers(in json: String, questions: [DraftItem]) -> [String: String] {
        var result: [String: String] = [:]
        for (id, question) in zip(ids(questions), questions) {
            if let text = partialString(for: id, in: json) {
                result[question.key] = humanized(text).trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }

    /// The (possibly unfinished) string value of `"key": "…` in `json`.
    static func partialString(for key: String, in json: String) -> String? {
        let scalars = Array(json.unicodeScalars)
        let needle = Array("\"\(key)\"".unicodeScalars)
        guard needle.count <= scalars.count else { return nil }
        var start: Int?
        var i = 0
        while start == nil, i + needle.count <= scalars.count {
            defer { i += 1 }
            guard Array(scalars[i..<(i + needle.count)]) == needle else { continue }
            var j = i + needle.count
            while j < scalars.count, scalars[j].properties.isWhitespace { j += 1 }
            guard j < scalars.count else { return nil }
            guard scalars[j] == ":" else { continue }
            j += 1
            while j < scalars.count, scalars[j].properties.isWhitespace { j += 1 }
            guard j < scalars.count else { return "" }
            guard scalars[j] == "\"" else { return nil }
            start = j + 1
        }
        guard let start else { return nil }
        var out = String.UnicodeScalarView()
        var k = start
        while k < scalars.count {
            let c = scalars[k]
            if c == "\"" { break }
            if c == "\\" {
                guard k + 1 < scalars.count else { break }
                let e = scalars[k + 1]
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": break
                case "u":
                    guard k + 5 < scalars.count,
                          let code = UInt32(String(String.UnicodeScalarView(scalars[(k + 2)...(k + 5)])), radix: 16) else { return String(out) }
                    if let scalar = Unicode.Scalar(code) { out.append(scalar) }
                    k += 6
                    continue
                default: out.append(e)
                }
                k += 2
                continue
            }
            out.append(c)
            k += 1
        }
        return String(out)
    }
}
