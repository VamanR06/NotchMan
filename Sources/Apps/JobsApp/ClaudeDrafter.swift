import Foundation

/// Drafts answers with Claude (Haiku by default) through your own `claude` command: your Claude Code sign-in, no
/// API key. It runs with no tools, no MCP servers and no saved session, from an empty folder, so it only sees what
/// it's handed: the job, its description, your resume and the questions.
struct ClaudeDrafter: Sendable {
    static let models = ["haiku", "sonnet"]

    enum DraftError: LocalizedError, Equatable {
        case notInstalled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: "Claude Code (claude) wasn't found. Install it from claude.com/claude-code, or switch drafts to Ollama in Settings."
            case .failed(let message): "Claude: \(message)"
            }
        }
    }

    /// Where `claude` is: the usual install places, else what a login shell finds (apps don't get the shell's PATH).
    static func findClaude() async -> String? {
        let home = NSHomeDirectory()
        let candidates = [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = await Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }

    /// An empty folder to run in, so Claude has nothing of yours to look at.
    static var scratchFolder: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchMan/drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// `claude -p` with no tools, streaming its reply as it writes.
    static func arguments(questions: [DraftItem], context: DraftContext, model: String, system: String) -> [String] {
        ["-p", AnswerDrafter.userPrompt(questions: questions, context: context),
         "--model", model,
         "--system-prompt", system,
         "--output-format", "stream-json", "--verbose", "--include-partial-messages",
         "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--disable-slash-commands"]
    }

    /// Same contract as `AnswerDrafter.draft`: answers so far by question key, a few times a second; the last is
    /// complete. Cancelling ends the `claude` process.
    func draft(questions: [DraftItem], context: DraftContext, model: String,
               system: String = AnswerDrafter.prompt.text) -> AsyncThrowingStream<[String: String], Error> {
        let arguments = Self.arguments(questions: questions, context: context, model: model, system: system)
        return AsyncThrowingStream { continuation in
            let process = Process()
            let task = Task {
                do {
                    guard let path = await Self.findClaude() else { throw DraftError.notInstalled }
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = arguments
                    process.currentDirectoryURL = Self.scratchFolder
                    process.standardInput = FileHandle.nullDevice
                    let output = Pipe(), errors = Pipe()
                    process.standardOutput = output
                    process.standardError = errors
                    try process.run()
                    let timeout = Task.detached {
                        try await Task.sleep(for: .seconds(150))
                        if process.isRunning { process.terminate() }
                    }
                    defer { timeout.cancel() }

                    var reader = StreamReader()
                    var lastYield = Date.distantPast
                    for try await line in output.fileHandleForReading.bytes.lines {
                        try Task.checkCancellation()
                        guard reader.feed(line) else { continue }
                        if Date().timeIntervalSince(lastYield) > 0.15 {
                            continuation.yield(AnswerDrafter.answers(in: reader.text, questions: questions))
                            lastYield = Date()
                        }
                    }
                    process.waitUntilExit()
                    if let error = reader.error { throw DraftError.failed(error) }
                    let final = AnswerDrafter.answers(in: reader.result ?? reader.text, questions: questions)
                    if final.values.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        throw DraftError.failed(message.isEmpty ? "it didn't write any answers. Try Redraft." : String(message.suffix(300)))
                    }
                    continuation.yield(final)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// Reads `claude -p --output-format stream-json`, one line at a time: the reply so far and the final result.
    struct StreamReader {
        private(set) var text = ""
        private(set) var result: String?
        private(set) var error: String?

        /// True when the text so far changed.
        mutating func feed(_ line: String) -> Bool {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
            switch object["type"] as? String {
            case "stream_event":
                let event = object["event"] as? [String: Any]
                guard let delta = event?["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                      let piece = delta["text"] as? String else { return false }
                text += piece
                return true
            case "result":
                if object["is_error"] as? Bool == true {
                    error = (object["result"] as? String) ?? "it couldn't answer."
                } else {
                    result = object["result"] as? String
                }
                return false
            default:
                return false
            }
        }
    }
}
