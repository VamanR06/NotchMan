import Foundation
import Observation

/// One row of a session's conversation, as the native session view shows it.
struct TranscriptEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        /// What you asked.
        case prompt(String)
        /// Claude's answer (Markdown).
        case reply(String)
        /// A tool Claude used, with its result once it's back.
        case tool(ToolCall)
    }

    let id: String
    let time: Date?
    var kind: Kind
}

/// A tool call and (once it arrives) its result.
struct ToolCall: Equatable {
    enum Detail: Equatable {
        case command(String)
        case edit(path: String, old: String, new: String)
        case write(path: String, content: String)
        case read(path: String)
        case search(String)
        case other
    }

    let id: String
    let name: String
    /// One line: the command, the file, the query.
    let summary: String
    let detail: Detail
    var result: String?
    var isError = false

    var isFinished: Bool { result != nil }

    /// The file it read or changed, for previewing.
    var path: String? {
        switch detail {
        case .edit(let path, _, _), .write(let path, _), .read(let path): path
        default: nil
        }
    }
}

/// Turns Claude Code's transcript lines (`~/.claude/projects/<project>/<session>.jsonl`) into entries. Fed new data as
/// the file grows; keeps a partial last line until its newline arrives, and attaches tool results to their calls.
struct TranscriptParser {
    private(set) var entries: [TranscriptEntry] = []
    /// Claude Code's own title for the session, when it has made one.
    private(set) var title: String?
    private var partial = Data()
    private var toolIndex: [String: Int] = [:]
    private var seen = Set<String>()

    mutating func feed(_ data: Data) {
        partial.append(data)
        guard let lastNewline = partial.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = partial[partial.startIndex..<lastNewline]
        partial = Data(partial[partial.index(after: lastNewline)...])
        for line in complete.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            add(object)
        }
    }

    private mutating func add(_ line: [String: Any]) {
        let type = line["type"] as? String
        if type == "ai-title", let aiTitle = line["aiTitle"] as? String, !aiTitle.isEmpty {
            title = aiTitle
            return
        }
        // Subagents' own conversations and Claude Code's bookkeeping messages aren't part of the session as you see it.
        guard type == "user" || type == "assistant", line["isSidechain"] as? Bool != true, line["isMeta"] as? Bool != true,
              let message = line["message"] as? [String: Any] else { return }
        let uuid = line["uuid"] as? String ?? UUID().uuidString
        let time = (line["timestamp"] as? String).flatMap(UsageScanner.parseDate)
        if let text = message["content"] as? String {
            if type == "user", let prompt = Self.prompt(text) { append(id: uuid, time: time, .prompt(prompt)) }
            return
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return }
        for (index, block) in blocks.enumerated() {
            let id = "\(uuid)-\(index)"
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String else { continue }
                if type == "assistant" {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { append(id: id, time: time, .reply(trimmed)) }
                } else if let prompt = Self.prompt(text) {
                    append(id: id, time: time, .prompt(prompt))
                }
            case "tool_use":
                guard let toolID = block["id"] as? String, let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                let call = ToolCall(id: toolID, name: name, summary: Self.summary(name: name, input: input),
                                    detail: Self.detail(name: name, input: input))
                if append(id: id, time: time, .tool(call)) { toolIndex[toolID] = entries.count - 1 }
            case "tool_result":
                guard let toolID = block["tool_use_id"] as? String, let index = toolIndex[toolID],
                      case .tool(var call) = entries[index].kind else { continue }
                call.result = Self.resultText(block["content"])
                call.isError = block["is_error"] as? Bool == true
                entries[index].kind = .tool(call)
            default:
                continue  // thinking, images, …
            }
        }
    }

    /// Streamed replies are logged more than once with the same ids.
    @discardableResult
    private mutating func append(id: String, time: Date?, _ kind: TranscriptEntry.Kind) -> Bool {
        guard seen.insert(id).inserted else { return false }
        entries.append(TranscriptEntry(id: id, time: time, kind: kind))
        return true
    }

    /// A prompt you typed, or nil for Claude Code's own wrappers (command echoes, caveats, reminders).
    static func prompt(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("[Request interrupted") else { return nil }
        return trimmed
    }

    static func summary(name: String, input: [String: Any]) -> String {
        let string = { (key: String) in input[key] as? String }
        switch name {
        case "Bash": return string("description") ?? string("command") ?? ""
        case "Read", "Write", "Edit", "NotebookEdit":
            return string("file_path").map { NSString(string: $0).abbreviatingWithTildeInPath } ?? ""
        case "Grep", "Glob": return string("pattern") ?? ""
        case "WebFetch": return string("url") ?? ""
        case "WebSearch": return string("query") ?? ""
        case "Agent", "Task": return string("description") ?? ""
        case "Skill": return string("skill") ?? ""
        default: return string("description") ?? string("command") ?? ""
        }
    }

    static func detail(name: String, input: [String: Any]) -> ToolCall.Detail {
        let string = { (key: String) in input[key] as? String }
        switch name {
        case "Bash": return string("command").map(ToolCall.Detail.command) ?? .other
        case "Edit":
            guard let path = string("file_path") else { return .other }
            return .edit(path: path, old: string("old_string") ?? "", new: string("new_string") ?? "")
        case "Write":
            guard let path = string("file_path") else { return .other }
            return .write(path: path, content: string("content") ?? "")
        case "Read": return string("file_path").map { .read(path: $0) } ?? .other
        case "Grep", "Glob", "WebSearch": return (string("pattern") ?? string("query")).map(ToolCall.Detail.search) ?? .other
        default: return .other
        }
    }

    /// A result's text, cut to what fits in a row's expanded view.
    static func resultText(_ content: Any?) -> String {
        let text: String
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            text = ""
        }
        return text.count > 4000 ? String(text.prefix(4000)) + "\n…" : text
    }
}

/// A background session's transcript, read as Claude Code writes it. Follows the file while `follow()` runs.
@MainActor @Observable
final class SessionTranscript {
    private(set) var entries: [TranscriptEntry] = []
    private(set) var title: String?
    /// False until the transcript file is found.
    private(set) var isLoaded = false

    let sessionID: String
    @ObservationIgnored private var parser = TranscriptParser()
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var offset: UInt64 = 0

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// Reads what's new every half second until cancelled (the view's `.task`).
    func follow(directory: URL = UsageScanner.projectsDirectory) async {
        while !Task.isCancelled {
            readNew(directory: directory)
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    func readNew(directory: URL = UsageScanner.projectsDirectory) {
        if file == nil { file = Self.find(sessionID: sessionID, in: directory) }
        guard let file, let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset {  // rewritten: start over
            offset = 0
            parser = TranscriptParser()
        }
        guard size > offset || !isLoaded else { return }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        parser.feed(data)
        if parser.entries != entries { entries = parser.entries }
        if parser.title != title { title = parser.title }
        isLoaded = true
    }

    /// `<projects>/<any project>/<session id>.jsonl`.
    static func find(sessionID: String, in directory: URL) -> URL? {
        let name = sessionID + ".jsonl"
        let projects = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return projects.lazy.map { $0.appending(path: name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
