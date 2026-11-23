import Foundation
import Testing
@testable import ChatApp

@MainActor @Suite struct ClaudeFallbackTests {
    @Test func askingIsReadOnlyAndNeverWaitsForPermission() {
        let args = ClaudeFallback.askArguments(question: "what's in my downloads?", frontmostApp: "Finder")
        #expect(args.first == "-p")
        let value = { (flag: String) in args.firstIndex(of: flag).map { args[$0 + 1] } }
        #expect(value("--disallowedTools") == "Bash,Edit,Write,NotebookEdit", "Claude can look things up but not change anything")
        #expect(value("--permission-mode") == "dontAsk", "anything else is refused on the spot, never a prompt to wait on")
        #expect(value("--output-format") == "stream-json" && args.contains("--include-partial-messages"))
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
        #expect(rows.map(\.id) == ["claude.ask", "chatgpt.ask", "chat.chatgpt", "chat.claude", "claude.agent"])
        #expect(rows[0].answer != nil && rows[1].answer != nil, "Claude and ChatGPT answer in the bar")
        #expect(!rows[2].needsConfirm && !rows[3].needsConfirm, "asking in a chat tab just sends it")
        #expect(rows[4].needsConfirm, "starting an agent asks first")
    }

    @Test func theStreamIsReadAsItComes() {
        var reader = ClaudeFallback.StreamReader()
        let delta = { (text: String) in
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}}"#
        }
        #expect(reader.feed(delta("Hello") + "\n" + delta(" the").prefix(30)) == true)
        #expect(reader.text == "Hello", "a half line waits for the rest")
        _ = reader.feed(String(delta(" the").dropFirst(30)) + "\n")
        #expect(reader.text == "Hello the")
        _ = reader.feed(#"{"type":"stream_event","event":{"type":"message_start","message":{}}}"# + "\n" + delta("re") + "\n")
        #expect(reader.text == "Hello the\n\nre", "a new message after a tool call starts a new paragraph")
        _ = reader.feed(#"{"type":"result","subtype":"success","result":"Hello there"}"# + "\n")
        #expect(reader.result == "Hello there")
    }
}
