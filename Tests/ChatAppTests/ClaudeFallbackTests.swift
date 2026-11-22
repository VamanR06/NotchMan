import Foundation
import Testing
@testable import ChatApp

@MainActor @Suite struct ClaudeFallbackTests {
    @Test func askingIsReadOnly() {
        let args = ClaudeFallback.askArguments(question: "what's in my downloads?", frontmostApp: "Finder")
        #expect(args.first == "-p")
        let disallowed = args.firstIndex(of: "--disallowedTools").map { args[$0 + 1] }
        #expect(disallowed == "Bash,Edit,Write,NotebookEdit", "Claude can look things up but not change anything")
        #expect(args.contains("--max-turns"))
        #expect(args[1].contains("what's in my downloads?") && args[1].contains("Finder"))
    }

    private func agent(_ id: String, cwd: String, started: TimeInterval, kind: ClaudeAgent.Kind = .background) -> ClaudeAgent {
        ClaudeAgent(id: id, shortID: id, name: id, cwd: cwd, kind: kind, state: "done", status: "idle",
                    startedAt: Date(timeIntervalSince1970: started))
    }

    @Test func agentsStartInTheLatestProjectsMainFolder() {
        let agents = [
            agent("old", cwd: "/repo/a", started: 100),
            agent("new", cwd: "/repo/b/.claude/worktrees/fix-x", started: 200),
            agent("ide", cwd: "/repo/c", started: 300, kind: .interactive),
        ]
        #expect(ClaudeFallback.agentFolder(for: agents, home: "/home") == "/repo/b", "not the worktree, not interactive")
        #expect(ClaudeFallback.agentFolder(for: [], home: "/home") == "/home")
    }

    @Test func everyRequestGetsAskStartAndChat() {
        let app = ChatApp()
        #expect(app.claudeFallbacks(for: "  ").isEmpty)
        let rows = app.claudeFallbacks(for: "rename my screenshots by date")
        #expect(rows.map(\.id) == ["claude.ask", "claude.agent", "claude.chat"])
        #expect(rows[0].answer != nil, "answered in the bar")
        #expect(rows[1].needsConfirm, "starting an agent asks first")
        #expect(!rows[2].needsConfirm)
    }
}
