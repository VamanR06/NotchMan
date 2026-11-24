import Foundation
import NotchKit

/// What the command bar falls back to when a request isn't one of the apps' actions: ask Claude (answered in the bar,
/// read-only), start a Claude Code agent to do it (asks before every edit and command, approvals in the notch), or
/// open a Claude chat with it typed in.
enum ClaudeFallback {
    /// `claude -p` that can only read and look things up, never asks for permission (anything else is refused on the
    /// spot, so it can't sit waiting on a prompt), and streams its answer as it writes it.
    static func askArguments(question: String, frontmostApp: String?) -> [String] {
        ["-p", prompt(question: question, frontmostApp: frontmostApp),
         "--output-format", "stream-json", "--verbose", "--include-partial-messages",
         "--permission-mode", "dontAsk",
         "--allowedTools", "Read,Glob,Grep,WebSearch,WebFetch",
         "--disallowedTools", "Bash,Edit,Write,NotebookEdit",
         "--max-turns", "6"]
    }

    /// Reads `claude -p --output-format stream-json` output line by line: the text so far, and the final answer.
    struct StreamReader: AnswerStream {
        private(set) var text = ""
        private(set) var result: String?
        private var partial = ""

        /// Feeds output; returns true when the text so far changed.
        mutating func feed(_ chunk: String) -> Bool {
            partial += chunk
            var changed = false
            while let newline = partial.firstIndex(of: "\n") {
                let line = String(partial[..<newline])
                partial = String(partial[partial.index(after: newline)...])
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                switch object["type"] as? String {
                case "stream_event":
                    let event = object["event"] as? [String: Any]
                    if event?["type"] as? String == "message_start", !text.isEmpty, !text.hasSuffix("\n\n") {
                        text += "\n\n"  // a new message after a tool call
                    }
                    if let delta = event?["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                       let piece = delta["text"] as? String {
                        text += piece
                        changed = true
                    }
                case "result":
                    result = object["result"] as? String
                    if object["is_error"] as? Bool == true, result == nil { result = "Claude couldn't answer." }
                default:
                    continue
                }
            }
            return changed
        }
    }

    static func prompt(question: String, frontmostApp: String?) -> String {
        answerPrompt.render(["app": frontmostApp.map { "The user is in \($0)." } ?? "", "request": question])
    }

    /// What Claude (or Codex) reads to answer the command bar, as you've edited it in Settings → Prompts.
    static let answerPrompt = EditablePrompt(
        id: "chat.commandBarAnswer", group: "Command bar", title: "Answering a request",
        detail: "When you ask Claude or ChatGPT something from the command bar (⌥Space), this is what it reads.",
        placeholders: [.init("request", "what you typed"),
                       .init("app", "\"The user is in Safari.\" (empty when unknown)", required: false)],
        defaultText: """
            You're answering a request typed into NotchMan's command bar (a small panel in the Mac's notch). Reply in a \
            few sentences of plain text, no headings. You can read and look things up but not change anything here; if \
            it needs changes made, say what to do or suggest starting a Claude Code agent for it.
            {app}

            Request: {request}
            """)

    /// Where an agent for a request starts: the project of the most recently started session (its main folder, not a
    /// worktree), else your home folder.
    static func agentFolder(for agents: [ClaudeAgent], home: String = NSHomeDirectory()) -> String {
        let latest = agents.filter { $0.kind == .background }.max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        return latest.map { ClaudeAgentsMonitor.projectFolder($0.cwd) } ?? home
    }
}

extension ChatApp {
    /// The bar's fallback rows for anything typed.
    func claudeFallbacks(for query: String) -> [CommandItem] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        let folder = ClaudeFallback.agentFolder(for: agentMonitor?.agents ?? [])
        let project = (folder as NSString).lastPathComponent
        return [
            CommandItem(id: "claude.ask", title: "Ask Claude: “\(text)”", subtitle: "Answered here · can read, can't change anything",
                        symbol: "sparkle", kind: "Claude", answer: { [weak self] progress in
                guard let self else { return "" }
                return try await self.askClaude(text, progress: progress)
            }),
            CommandItem(id: "chatgpt.ask", title: "Ask ChatGPT: “\(text)”", subtitle: "Answered here · through Codex, read-only",
                        symbol: "bubble.left.and.text.bubble.right", kind: "ChatGPT", answer: { [weak self] progress in
                guard let self else { return "" }
                return try await self.askChatGPT(text, progress: progress)
            }),
            CommandItem(id: "chat.chatgpt", title: "Ask in a ChatGPT chat: “\(text)”", subtitle: "Sends it in the ChatGPT tab",
                        symbol: "bubble.left", kind: "Chat", revealsApp: id) {
                AskAI.shared.send(text, service: ChatService.chatgpt.rawValue, submit: true)
            },
            CommandItem(id: "chat.claude", title: "Ask in a Claude chat: “\(text)”", subtitle: "Sends it in the Claude tab",
                        symbol: "bubble.left", kind: "Chat", revealsApp: id) {
                AskAI.shared.send(text, service: ChatService.claude.rawValue, submit: true)
            },
            CommandItem(id: "claude.agent", title: "Start a Claude Code agent: “\(text)”",
                        subtitle: "In \(project) · asks before every edit and command", symbol: "terminal", kind: "Claude",
                        revealsApp: id, needsConfirm: true) { [weak self] in
                self?.startAgent(text, in: folder)
            },
        ]
    }

    /// Asks Claude Code (read-only), passing the answer to `progress` as it streams in. Cancelling stops it.
    func askClaude(_ question: String, progress: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let path = await agentMonitor.claudePath() else { throw Shell.ShellError.failed("Claude Code (claude) wasn't found.") }
        let front = IntentContext.current().frontmostApp
        let arguments = ClaudeFallback.askArguments(question: question, frontmostApp: front)
        let answer = try await ClaudeProcess.stream(path, arguments, timeout: 180) { text in
            Task { @MainActor in progress(text) }
        }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Claude didn't answer." : trimmed
    }

    /// Asks ChatGPT through the Codex CLI (`codex exec`, signed in with your ChatGPT account), read-only and without
    /// keeping a session, in a scratch folder so it has nothing of yours to look at. Codex hands back whole messages,
    /// not a word at a time, so the answer arrives in one go.
    func askChatGPT(_ question: String, progress: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let path = await CodexCLI.path() else {
            throw Shell.ShellError.failed("ChatGPT answers here need the Codex CLI: npm i -g @openai/codex, then codex login.")
        }
        let front = IntentContext.current().frontmostApp
        let answer = try await ClaudeProcess.stream(path, CodexCLI.askArguments(question: question, frontmostApp: front),
                                                    timeout: 180, in: CodexCLI.scratchFolder,
                                                    reader: CodexCLI.StreamReader.self) { text in
            Task { @MainActor in progress(text) }
        }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "ChatGPT didn't answer." : trimmed
    }

    func startAgent(_ prompt: String, in folder: String) {
        showingOverview = true
        backToOverview()
        Task {
            do {
                try await agentMonitor.dispatch(prompt: prompt, in: folder, mode: .manual)
                context?.showTransient(NotchTransient(id: "agent", systemImage: "terminal", text: "Agent started", tint: .green))
            } catch {
                context?.showTransient(NotchTransient(id: "agent", systemImage: "exclamationmark.triangle.fill",
                                                      text: "Couldn't start", tint: .orange, duration: 2.5))
            }
        }
    }
}


/// Runs `claude -p` with streamed JSON output, reporting the text so far; cancelling the task stops the process.
/// Streamed output of a CLI that answers a question: the text so far, and the final answer once it's done.
protocol AnswerStream: Sendable {
    init()
    /// Feeds output; returns true when the text so far changed.
    mutating func feed(_ chunk: String) -> Bool
    var text: String { get }
    var result: String? { get }
}

enum ClaudeProcess {
    static func stream<Reader: AnswerStream>(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                                             in folder: String = NSHomeDirectory(),
                                             reader readerType: Reader.Type = ClaudeFallback.StreamReader.self,
                                             onText: @escaping @Sendable (String) -> Void) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let reader = Locked(readerType.init())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                output.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = String(decoding: handle.availableData, as: UTF8.self)
                    if let text = reader.update({ $0.feed(chunk) ? $0.text : nil }) { onText(text) }
                }
                process.terminationHandler = { process in
                    output.fileHandleForReading.readabilityHandler = nil
                    let rest = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    let (text, result) = reader.update { reader -> (String, String?) in
                        _ = reader.feed(rest + "\n")
                        return (reader.text, reader.result)
                    }
                    if let answer = result ?? (text.isEmpty ? nil : text) {
                        continuation.resume(returning: answer)
                    } else if process.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: Shell.ShellError.failed(message.isEmpty ? "It stopped without answering." : String(message.suffix(300))))
                    }
                }
                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// A value shared between the pipe's callbacks.
    final class Locked<Value>: @unchecked Sendable {
        private var value: Value
        private let lock = NSLock()

        init(_ value: Value) { self.value = value }

        func update<T>(_ body: (inout Value) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }
}

/// The Codex CLI (`codex`), OpenAI's terminal agent, used to ask ChatGPT from the command bar with your ChatGPT sign-in.
enum CodexCLI {
    @MainActor private static var resolved: String?

    @MainActor
    static func path() async -> String? {
        if let resolved { return resolved }
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.npm-global/bin/codex"]
        if let found = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            resolved = found
            return found
        }
        let fromShell = try? await Shell.run("/bin/zsh", ["-lc", "command -v codex"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let fromShell, !fromShell.isEmpty, FileManager.default.isExecutableFile(atPath: fromShell) { resolved = fromShell }
        return resolved
    }

    /// An empty folder to run in, so a read-only Codex has nothing of yours to read.
    static var scratchFolder: String {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchMan/chatgpt", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.path
    }

    static func askArguments(question: String, frontmostApp: String?) -> [String] {
        ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral", "--color", "never",
         ClaudeFallback.prompt(question: question, frontmostApp: frontmostApp)]
    }

    /// Reads `codex exec --json`: each finished `agent_message` item adds to the answer; a failed turn is the error.
    struct StreamReader: AnswerStream {
        private(set) var text = ""
        private(set) var result: String?
        private var partial = ""

        init() {}

        mutating func feed(_ chunk: String) -> Bool {
            partial += chunk
            var changed = false
            while let newline = partial.firstIndex(of: "\n") {
                let line = String(partial[..<newline])
                partial = String(partial[partial.index(after: newline)...])
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                switch object["type"] as? String {
                case "item.completed":
                    guard let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message",
                          let message = item["text"] as? String, !message.isEmpty else { continue }
                    text += (text.isEmpty ? "" : "\n\n") + message
                    changed = true
                case "turn.completed":
                    result = text
                case "turn.failed", "error":
                    let error = (object["error"] as? [String: Any])?["message"] as? String ?? object["message"] as? String
                    result = text.isEmpty ? "ChatGPT couldn't answer" + (error.map { ": \($0)" } ?? ".") : text
                default:
                    continue
                }
            }
            return changed
        }
    }
}
