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
        /// Claude Code's recap of the session, written when you come back to it (above your next prompt).
        case recap(String)
        /// A notice from Claude Code itself, like a hook or mod reloading.
        case notice(String)
        /// A slash command you ran ("/compact"), and what it printed.
        case command(String, output: String?)
    }

    let id: String
    let time: Date?
    var kind: Kind
}

/// One item of Claude's plan for the turn (TodoWrite, or TaskCreate / TaskUpdate).
struct TodoItem: Equatable, Sendable, Identifiable {
    enum Status: String, Sendable { case pending, inProgress = "in_progress", completed }
    let id: String
    var title: String
    var status: Status
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
struct TranscriptParser: Sendable {
    private(set) var entries: [TranscriptEntry] = []
    /// Claude Code's own title for the session, when it has made one.
    private(set) var title: String?
    /// Whether Claude is mid-turn, as the file says: a prompt opens a turn, and Claude's last message of it
    /// (`stop_reason: end_turn`, then a `turn_duration` line) closes it. Nil until the file shows either.
    private(set) var turnOpen: Bool?
    /// Claude's plan as it stands, from its to-do / task tools — or, until Claude makes a list, the steps of the plan
    /// you just approved.
    private(set) var todos: [TodoItem] = []
    /// `todos` are the approved plan's steps, not Claude's own list: nothing ticks them off.
    private(set) var todosFromPlan = false
    /// The last prompt you took back with Esc before Claude answered.
    private(set) var withdrawnPrompt: String?
    /// TaskCreate calls waiting for their result, which carries the task's number.
    private var pendingTasks: [String: String] = [:]
    /// ExitPlanMode calls waiting for your answer, with their plan.
    private var pendingPlans: [String: String] = [:]
    /// Tool calls already counted toward the plan (Claude Code logs some lines twice).
    private var plannedTools = Set<String>()
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
        if type == "system" {
            let content = (line["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let id = line["uuid"] as? String ?? UUID().uuidString
            let time = (line["timestamp"] as? String).flatMap(UsageScanner.parseDate)
            switch line["subtype"] as? String {
            case "turn_duration": turnOpen = false
            case "away_summary" where !content.isEmpty: append(id: id, time: time, .recap(content))
            case "informational" where !content.isEmpty: append(id: id, time: time, .notice(Self.plain(content)))
            default: break
            }
            return
        }
        if type == "attachment" {
            // A message you sent while Claude was working goes in mid-turn, logged only as an attachment.
            if line["isSidechain"] as? Bool != true, let attachment = line["attachment"] as? [String: Any],
               let text = Self.queuedPrompt(attachment) {
                append(id: line["uuid"] as? String ?? UUID().uuidString,
                       time: (line["timestamp"] as? String).flatMap(UsageScanner.parseDate), .prompt(text))
            }
            return
        }
        // Subagents' own conversations and Claude Code's bookkeeping messages aren't part of the session as you see it.
        guard type == "user" || type == "assistant", line["isSidechain"] as? Bool != true, line["isMeta"] as? Bool != true,
              let message = line["message"] as? [String: Any] else { return }
        let uuid = line["uuid"] as? String ?? UUID().uuidString
        let time = (line["timestamp"] as? String).flatMap(UsageScanner.parseDate)
        if type == "assistant", let stop = message["stop_reason"] as? String {
            turnOpen = stop == "tool_use"  // end_turn, stop_sequence, max_tokens… end it
        }
        if let text = message["content"] as? String {
            if type == "user" {
                if text.hasPrefix("[Request interrupted") { interrupted() }
                if let name = text.firstMatch(of: /<command-name>([^<]*)<\/command-name>/)?.output.1 {
                    let args = text.firstMatch(of: /<command-args>([^<]*)<\/command-args>/)?.output.1 ?? ""
                    append(id: uuid, time: time, .command((name + " " + args).trimmingCharacters(in: .whitespaces), output: nil))
                    return
                }
                if let output = text.firstMatch(of: /<local-command-stdout>([\s\S]*)<\/local-command-stdout>/)?.output.1,
                   let index = entries.lastIndex(where: { if case .command = $0.kind { true } else { false } }),
                   case .command(let name, nil) = entries[index].kind {
                    let plain = Self.plain(String(output)).trimmingCharacters(in: .whitespacesAndNewlines)
                    entries[index].kind = .command(name, output: plain.isEmpty ? nil : plain)
                    return
                }
                if let prompt = Self.prompt(text) {
                    append(id: uuid, time: time, .prompt(prompt))
                    turnOpen = true
                    clearFinishedTodos()
                }
            }
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
                } else if text.hasPrefix("[Request interrupted") {
                    interrupted()
                } else if let prompt = Self.prompt(text) {
                    append(id: id, time: time, .prompt(prompt))
                    turnOpen = true
                    clearFinishedTodos()
                }
            case "tool_use":
                guard let toolID = block["id"] as? String, let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                if plannedTools.insert(toolID).inserted { trackPlan(tool: name, id: toolID, input: input) }
                let call = ToolCall(id: toolID, name: name, summary: Self.summary(name: name, input: input),
                                    detail: Self.detail(name: name, input: input))
                if append(id: id, time: time, .tool(call)) { toolIndex[toolID] = entries.count - 1 }
            case "tool_result":
                if let toolID = block["tool_use_id"] as? String, let subject = pendingTasks.removeValue(forKey: toolID),
                   let number = Self.resultText(block["content"]).firstMatch(of: /Task #(\w+)/)?.output.1 {
                    dropPlanSteps()
                    if !todos.contains(where: { $0.id == String(number) }) {
                        todos.append(TodoItem(id: String(number), title: subject, status: .pending))
                    }
                }
                if let toolID = block["tool_use_id"] as? String, let plan = pendingPlans.removeValue(forKey: toolID),
                   block["is_error"] as? Bool != true, Self.resultText(block["content"]).hasPrefix("User has approved") {
                    planApproved(plan)
                }
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

    /// TodoWrite replaces the whole list; TaskCreate adds one (numbered once its result is back); TaskUpdate changes
    /// one's status or title.
    private mutating func trackPlan(tool: String, id: String, input: [String: Any]) {
        switch tool {
        case "TodoWrite":
            guard let items = input["todos"] as? [[String: Any]] else { return }
            todosFromPlan = false
            todos = items.enumerated().map { index, item in
                TodoItem(id: item["id"] as? String ?? "\(index)",
                         title: item["content"] as? String ?? item["activeForm"] as? String ?? "",
                         status: (item["status"] as? String).flatMap(TodoItem.Status.init(rawValue:)) ?? .pending)
            }
        case "TaskCreate":
            if let subject = input["subject"] as? String ?? input["description"] as? String { pendingTasks[id] = subject }
        case "ExitPlanMode":
            if let plan = input["plan"] as? String { pendingPlans[id] = plan }
        case "TaskUpdate":
            guard let taskID = (input["taskId"] as? String) ?? (input["taskId"] as? Int).map(String.init),
                  let index = todos.firstIndex(where: { $0.id == taskID }) else { return }
            if let status = input["status"] as? String {
                if status == "deleted" { todos.remove(at: index); return }
                if let parsed = TodoItem.Status(rawValue: status) { todos[index].status = parsed }
            }
            if let subject = input["subject"] as? String { todos[index].title = subject }
        default:
            return
        }
    }

    /// A new prompt starts a new stretch of work: steps already done drop off the plan (open ones stay).
    private mutating func clearFinishedTodos() {
        dropPlanSteps()
        todos.removeAll { $0.status == .completed }
    }

    /// You approved a plan: its steps stand in as the to-do list until Claude makes its own (it often doesn't).
    private mutating func planApproved(_ plan: String) {
        guard todos.allSatisfy({ $0.status == .completed }) else { return }  // Claude's own list is still going
        let steps = PlanSteps.steps(plan)
        guard !steps.isEmpty else { return }
        todos = steps.enumerated().map { TodoItem(id: "plan-\($0.offset)", title: $0.element, status: .pending) }
        todosFromPlan = true
    }

    /// Claude's own list replaces the plan's steps.
    private mutating func dropPlanSteps() {
        guard todosFromPlan else { return }
        todos = []
        todosFromPlan = false
    }

    /// The text of a message you sent mid-turn (a `queued_command` attachment), or nil for anything else — including
    /// background-task and subagent notices, which are queued the same way.
    static func queuedPrompt(_ attachment: [String: Any]) -> String? {
        guard attachment["type"] as? String == "queued_command" else { return nil }
        if let origin = (attachment["origin"] as? [String: Any])?["kind"] as? String, origin != "human" { return nil }
        if let mode = attachment["commandMode"] as? String, mode != "prompt" { return nil }
        let text: String
        if let string = attachment["prompt"] as? String {
            text = string
        } else if let blocks = attachment["prompt"] as? [[String: Any]] {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
            return nil
        }
        return prompt(text)
    }

    /// You pressed Esc. If Claude hadn't done anything for your prompt yet, it goes back to the input box in Claude
    /// Code — so it leaves the conversation here too.
    private mutating func interrupted() {
        turnOpen = false
        if case .prompt(let text)? = entries.last?.kind {
            withdrawnPrompt = text
            entries.removeLast()
        }
    }

    /// Text without terminal colour codes.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
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
    private(set) var entries: [TranscriptEntry] = [] {
        didSet {
            settlePending()
            refreshItems()
        }
    }
    /// The entries as the session view shows them (tool calls grouped), plus messages you sent that Claude Code
    /// hasn't logged yet; worked out once per change.
    private(set) var items: [SessionItem] = []
    /// Messages you sent (here or from a notification) that aren't in the file yet. One sent while Claude works is
    /// logged only once Claude takes it in, at its next step — until then it shows from here, as in Claude's terminal.
    @ObservationIgnored private var pending: [PendingPrompt] = []

    private struct PendingPrompt {
        let entry: TranscriptEntry
        let key: String
        /// How many entries there were when it was sent: its logged copy comes after them.
        let after: Int
        let sent: Date
    }

    /// How long a sent message shows without Claude Code logging it (it was dropped, or edited past recognition).
    static let pendingLifetime: TimeInterval = 180
    private(set) var title: String?
    /// Claude is mid-turn, per the file (nil until it says); see `TranscriptParser.turnOpen`.
    private(set) var turnOpen: Bool?
    /// Claude's plan, from its to-do / task tools.
    private(set) var todos: [TodoItem] = []
    /// `todos` are an approved plan's steps (nothing ticks them off), not Claude's own list.
    private(set) var todosFromPlan = false
    /// The last prompt you took back with Esc before Claude answered (the session view returns it to the box).
    private(set) var withdrawnPrompt: String?
    /// False until the transcript file is found.
    private(set) var isLoaded = false

    let sessionID: String
    @ObservationIgnored private var parser = TranscriptParser()
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var offset: UInt64 = 0

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// Reads what's new every half second until cancelled (the view's `.task`). The first read of a long session
    /// (megabytes of history) is parsed off the main thread, so opening it doesn't stall the notch.
    func follow(directory: URL = UsageScanner.projectsDirectory) async {
        if !isLoaded { await loadInBackground(directory: directory) }
        while !Task.isCancelled {
            readNew(directory: directory)
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func loadInBackground(directory: URL) async {
        if file == nil { file = Self.find(sessionID: sessionID, in: directory) }
        guard let file, offset == 0 else { return }
        let start = parser
        let (parsed, size) = await Task.detached(priority: .userInitiated) { () -> (TranscriptParser, UInt64) in
            var parser = start
            guard let data = try? Data(contentsOf: file) else { return (parser, 0) }
            // Only whole lines; the rest is read normally once its newline is written.
            let end = data.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? 0
            parser.feed(data.prefix(end))
            return (parser, UInt64(end))
        }.value
        guard offset == 0, size > 0 else { return }
        parser = parsed
        offset = size
        if parser.entries != entries { entries = parser.entries }
        if parser.title != title { title = parser.title }
        if parser.turnOpen != turnOpen { turnOpen = parser.turnOpen }
        if parser.todos != todos { todos = parser.todos }
        if parser.todosFromPlan != todosFromPlan { todosFromPlan = parser.todosFromPlan }
        if parser.withdrawnPrompt != withdrawnPrompt { withdrawnPrompt = parser.withdrawnPrompt }
        isLoaded = true
    }

    func readNew(directory: URL = UsageScanner.projectsDirectory) {
        if file == nil { file = Self.find(sessionID: sessionID, in: directory) }
        guard let file, let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        settlePending()
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
        if parser.turnOpen != turnOpen { turnOpen = parser.turnOpen }
        if parser.todos != todos { todos = parser.todos }
        if parser.todosFromPlan != todosFromPlan { todosFromPlan = parser.todosFromPlan }
        if parser.withdrawnPrompt != withdrawnPrompt { withdrawnPrompt = parser.withdrawnPrompt }
        isLoaded = true
    }

    /// Shows a message you just sent until Claude Code logs it. Slash commands are left out (they show as their own
    /// rows once run).
    func expect(_ text: String, now: Date = Date()) {
        guard let prompt = TranscriptParser.prompt(text), !prompt.hasPrefix("/") else { return }
        let entry = TranscriptEntry(id: "pending-" + UUID().uuidString, time: now, kind: .prompt(prompt))
        pending.append(PendingPrompt(entry: entry, key: Self.matchKey(prompt), after: entries.count, sent: now))
        refreshItems()
    }

    /// Drops sent messages that are now in the file, or that have waited too long.
    private func settlePending(now: Date = Date()) {
        guard !pending.isEmpty else { return }
        let before = pending.count
        pending.removeAll { sent in
            if now.timeIntervalSince(sent.sent) > Self.pendingLifetime { return true }
            return entries[min(sent.after, entries.count)...].contains { entry in
                guard case .prompt(let text) = entry.kind else { return false }
                let key = Self.matchKey(text)
                return key.hasPrefix(sent.key) || sent.key.hasPrefix(key)
            }
        }
        if pending.count != before { refreshItems() }
    }

    private func refreshItems() {
        items = SessionItem.items(entries + pending.map(\.entry))
    }

    /// Letters and digits from the start of a message: Claude Code may log it with image markers or trimmed.
    private static func matchKey(_ text: String) -> String {
        String(String(text.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init)).lowercased().prefix(40))
    }

    /// Claude's last reply in a session (read from the end of its transcript), for notifications.
    static func lastReply(sessionID: String, directory: URL = UsageScanner.projectsDirectory) -> String? {
        guard let file = find(sessionID: sessionID, in: directory), let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 300_000 ? size - 300_000 : 0)
        var parser = TranscriptParser()
        parser.feed((try? handle.readToEnd()) ?? Data())  // a cut-off first line just doesn't parse
        for entry in parser.entries.reversed() {
            if case .reply(let text) = entry.kind { return text }
        }
        return nil
    }

    /// `<projects>/<any project>/<session id>.jsonl`.
    static func find(sessionID: String, in directory: URL) -> URL? {
        let name = sessionID + ".jsonl"
        let projects = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return projects.lazy.map { $0.appending(path: name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
