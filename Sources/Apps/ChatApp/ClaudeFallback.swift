import Foundation
import NotchKit

/// What the command bar falls back to when a request isn't one of the apps' actions: ask Claude (answered in the bar,
/// read-only), start a Claude Code agent to do it (asks before every edit and command, approvals in the notch), or
/// open a Claude chat with it typed in.
enum ClaudeFallback {
    /// `claude -p` with tools that can't change anything: Claude can look things up but not edit or run commands.
    static func askArguments(question: String, frontmostApp: String?) -> [String] {
        ["-p", prompt(question: question, frontmostApp: frontmostApp),
         "--output-format", "text",
         "--disallowedTools", "Bash,Edit,Write,NotebookEdit",
         "--max-turns", "6"]
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
                        symbol: "sparkle", kind: "Claude", answer: { [weak self] in
                guard let self else { return "" }
                return try await self.askClaude(text)
            }),
            CommandItem(id: "claude.agent", title: "Start a Claude Code agent: “\(text)”",
                        subtitle: "In \(project) · asks before every edit and command", symbol: "terminal", kind: "Claude",
                        revealsApp: id, needsConfirm: true) { [weak self] in
                self?.startAgent(text, in: folder)
            },
            CommandItem(id: "claude.chat", title: "Open a Claude chat with this", symbol: "bubble.left", kind: "Claude",
                        revealsApp: id) {
                AskAI.shared.send(text, service: "claude")
            },
        ]
    }

    func askClaude(_ question: String) async throws -> String {
        guard let path = await agentMonitor.claudePath() else { throw Shell.ShellError.failed("Claude Code (claude) wasn't found.") }
        let front = IntentContext.current().frontmostApp
        let output = try await Shell.run(path, ClaudeFallback.askArguments(question: question, frontmostApp: front),
                                         in: NSHomeDirectory(), timeout: 120)
        let answer = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? "Claude didn't answer." : answer
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
