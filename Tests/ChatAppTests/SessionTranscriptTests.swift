import Foundation
import Testing
@testable import ChatApp

/// Claude Code transcript lines → the rows the native session view shows.
@MainActor @Suite struct SessionTranscriptTests {
    /// Shaped like real transcript lines (Claude Code 2.1.3xx), trimmed to the fields that matter.
    private let lines = [
        #"{"type":"ai-title","aiTitle":"Fix the build","sessionId":"s1"}"#,
        #"{"type":"user","uuid":"u1","timestamp":"2026-11-22T10:00:00.000Z","message":{"role":"user","content":"why does the build fail?"}}"#,
        #"{"type":"user","uuid":"u0","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>…</local-command-caveat>"}}"#,
        #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"}]}}"#,
        #"{"type":"assistant","uuid":"a2","message":{"role":"assistant","content":[{"type":"text","text":"Let me check."}]}}"#,
        #"{"type":"assistant","uuid":"a3","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift build","description":"Build the package"}}]}}"#,
        #"{"type":"assistant","uuid":"a3","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift build","description":"Build the package"}}]}}"#,
        #"{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"error: missing import","is_error":true}]}}"#,
        #"{"type":"assistant","uuid":"a4","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/tmp/a.swift","old_string":"let x","new_string":"import Foundation\nlet x","replace_all":false}}]}}"#,
        #"{"type":"assistant","uuid":"s9","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent chatter"}]}}"#,
    ]

    private func parsed(_ text: String) -> TranscriptParser {
        var parser = TranscriptParser()
        parser.feed(Data(text.utf8))
        return parser
    }

    @Test func turnsLinesIntoPromptsRepliesAndToolCalls() {
        let parser = parsed(lines.joined(separator: "\n") + "\n")
        #expect(parser.title == "Fix the build")
        let kinds = parser.entries.map(\.kind)
        #expect(kinds.count == 4, "meta, thinking, the repeated line and the subagent are left out: \(kinds)")
        #expect(kinds[0] == .prompt("why does the build fail?"))
        #expect(kinds[1] == .reply("Let me check."))
        guard case .tool(let bash) = kinds[2], case .tool(let edit) = kinds[3] else {
            Issue.record("expected two tool calls")
            return
        }
        #expect(bash.name == "Bash" && bash.summary == "Build the package" && bash.detail == .command("swift build"))
        #expect(bash.result == "error: missing import" && bash.isError, "the result is attached to its call")
        #expect(edit.detail == .edit(path: "/tmp/a.swift", old: "let x", new: "import Foundation\nlet x"))
        #expect(!edit.isFinished && edit.path == "/tmp/a.swift")
    }

    @Test func waitsForTheRestOfAHalfWrittenLine() {
        let line = lines[1]
        var parser = TranscriptParser()
        parser.feed(Data(line.prefix(30).utf8))
        #expect(parser.entries.isEmpty)
        parser.feed(Data((line.dropFirst(30) + "\n").utf8))
        #expect(parser.entries.map(\.kind) == [.prompt("why does the build fail?")])
    }

    @Test func followsTheFileAsItGrows() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "transcripts-\(UUID().uuidString)")
        let project = folder.appending(path: "-Users-me-app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = project.appending(path: "s1.jsonl")
        try (lines[1] + "\n").write(to: file, atomically: true, encoding: .utf8)

        let transcript = SessionTranscript(sessionID: "s1")
        transcript.readNew(directory: folder)
        #expect(transcript.isLoaded && transcript.entries.count == 1)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines[4] + "\n").utf8))
        try handle.close()
        transcript.readNew(directory: folder)
        #expect(transcript.entries.map(\.kind).last == .reply("Let me check."))
    }

    @Test func ignoresClaudeCodesOwnWrappers() {
        #expect(TranscriptParser.prompt("<command-name>/clear</command-name>") == nil)
        #expect(TranscriptParser.prompt("[Request interrupted by user]") == nil)
        #expect(TranscriptParser.prompt("  fix it  ") == "fix it")
    }
}

/// What the message box types into Claude's terminal.
@MainActor @Suite struct SendToClaudeTests {
    @Test func oneLineIsTypedThenSubmitted() {
        #expect(AgentTerminal.input(for: "hi") == Array("hi".utf8) + [0x0D])
    }

    @Test func severalLinesGoInAsOnePaste() {
        let bytes = AgentTerminal.input(for: "a\nb")
        #expect(bytes.starts(with: Array("\u{1B}[200~".utf8)))
        #expect(bytes.suffix(7) == ArraySlice(Array("\u{1B}[201~".utf8) + [0x0D]))
    }
}
