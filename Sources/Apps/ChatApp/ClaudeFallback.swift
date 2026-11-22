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
    struct StreamReader {
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
        """
        You're answering a request typed into NotchMan's command bar (a small panel in the Mac's notch). Reply in a \
        few sentences of plain text, no headings. You can read and look things up but not change anything here; if \
        it needs changes made, say what to do or suggest starting a Claude Code agent for it.
        \(frontmostApp.map { "The user is in \($0)." } ?? "")

        Request: \(question)
        """
    }

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
            CommandItem(id: "chat.chatgpt", title: "Ask ChatGPT: “\(text)”", subtitle: "Sends it in the ChatGPT tab",
                        symbol: "bubble.left.and.text.bubble.right", kind: "Chat", revealsApp: id) {
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
enum ClaudeProcess {
    static func stream(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                       onText: @escaping @Sendable (String) -> Void) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let reader = Locked(ClaudeFallback.StreamReader())
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
                        continuation.resume(throwing: Shell.ShellError.failed(message.isEmpty ? "Claude stopped without answering." : message))
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
