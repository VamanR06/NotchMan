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

    /// A turn is open from your prompt until Claude's last message of it (end_turn, then turn_duration).
    @Test func knowsWhetherATurnIsRunning() {
        var parser = TranscriptParser()
        #expect(parser.turnOpen == nil)
        parser.feed(Data((#"{"type":"user","uuid":"u1","message":{"role":"user","content":"fix it"}}"# + "\n").utf8))
        #expect(parser.turnOpen == true)
        parser.feed(Data((#"{"type":"assistant","uuid":"a1","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"# + "\n").utf8))
        parser.feed(Data((#"{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"# + "\n").utf8))
        #expect(parser.turnOpen == true)
        parser.feed(Data((#"{"type":"assistant","uuid":"a2","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}"# + "\n").utf8))
        #expect(parser.turnOpen == false)
        parser.feed(Data((#"{"type":"system","subtype":"turn_duration","durationMs":1200}"# + "\n").utf8))
        #expect(parser.turnOpen == false)
        // Pressing Esc mid-turn ends it too.
        parser.feed(Data((#"{"type":"user","uuid":"u2","message":{"role":"user","content":"again"}}"# + "\n").utf8))
        parser.feed(Data((#"{"type":"user","uuid":"u3","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"# + "\n").utf8))
        #expect(parser.turnOpen == false)
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

    /// Claude Code files a transcript under its working directory and moves it when that changes (a session
    /// entering a worktree): the view must follow it to the new folder, not freeze on the old path.
    @Test func followsTheFileWhenClaudeMovesItToAnotherProject() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "transcripts-\(UUID().uuidString)")
        let main = folder.appending(path: "-Users-me-app")
        let worktree = folder.appending(path: "-Users-me-app--claude-worktrees-fix")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = main.appending(path: "s1.jsonl")
        try (lines[1] + "\n").write(to: before, atomically: true, encoding: .utf8)

        let transcript = SessionTranscript(sessionID: "s1")
        transcript.readNew(directory: folder)
        #expect(transcript.entries.count == 1)

        let after = worktree.appending(path: "s1.jsonl")
        try FileManager.default.moveItem(at: before, to: after)
        let handle = try FileHandle(forWritingTo: after)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines[4] + "\n").utf8))
        try handle.close()
        transcript.readNew(directory: folder)
        #expect(transcript.entries.count == 2, "picked up where it left off, nothing read twice")
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
    // Return is sent separately, later — in the same burst Claude Code takes it as a pasted line break.
    @Test func oneLineIsTypedWithoutReturn() {
        #expect(AgentTerminal.input(for: "hi") == Array("hi".utf8))
    }

    @Test func severalLinesGoInAsOnePaste() {
        let bytes = AgentTerminal.input(for: "a\nb")
        #expect(bytes.starts(with: Array("\u{1B}[200~".utf8)))
        #expect(bytes.suffix(6) == ArraySlice(Array("\u{1B}[201~".utf8)))
    }

    @Test func readsTheReplyBeingWrittenOffTheScreen() {
        let screen = [
            "> fix the build",
            "",
            "⏺ Bash(swift build)",
            "  ⎿  Build complete!",
            "",
            "⏺ The build works again. The cause was a missing",
            "  import in ShelfView.swift.",
            "",
            "  - added the import",
            "",
            "✻ Pondering… (12s · esc to interrupt)",
            "",
            "────────────────",
            "❯ ",
            "────────────────",
        ]
        #expect(AgentTerminal.liveReply(screen)
            == "The build works again. The cause was a missing\nimport in ShelfView.swift.\n\n- added the import")
    }

    @Test func spinnerAboveTheInputBoxMeansWorking() {
        let working = ["⏺ Writing…", "", "✻ Pondering… (12s · esc to interrupt)", "", "────", "❯ ", "────"]
        #expect(AgentTerminal.showsSpinner(working))
        // Finished: the spinner turns into a past-tense summary without the ellipsis.
        let done = ["⏺ All set.", "", "✻ Worked for 1m 4s", "", "────", "❯ ", "────", "  ? for shortcuts"]
        #expect(!AgentTerminal.showsSpinner(done))
        // A reply's own "…" further up isn't the spinner.
        let quoted = ["* step one…", "", "", "", "", "", "", "⏺ Done.", "", "────", "❯ ", "────"]
        #expect(!AgentTerminal.showsSpinner(quoted))
    }

    @Test func noLiveReplyWhileAToolRuns() {
        let screen = ["⏺ Done thinking.", "", "⏺ Bash(swift test)", "  ⎿  Running…", "", "────", "❯ ", "────"]
        #expect(AgentTerminal.liveReply(screen) == nil)
        #expect(AgentTerminal.liveReply(["⏺ Read 3 files (ctrl+o to expand)", "────", "❯ "]) == nil)
    }

    @Test func liveReplyMatchesTheSavedOneDespiteMarkdown() {
        #expect(AgentTerminal.reply("The build works again. The cause was a missing import in ShelfView.swift.",
                                    isIn: ["**The build works again.** The cause was a missing import in `ShelfView.swift`."]))
        #expect(!AgentTerminal.reply("Something new entirely, still being written", isIn: ["The build works again."]))
    }

    @Test func readsWhatsLeftInClaudesInputBox() {
        let screen = ["⏺ Done.", "", "────────────", "❯ fix the build", "────────────", "  ? for shortcuts"]
        #expect(AgentTerminal.promptText(screen) == "fix the build")
        #expect(AgentTerminal.promptText(["────", "❯ ", "────"]) == nil)
        #expect(AgentTerminal.submitProbe(for: "fix the build please and then run the tests") == "fix the build please and")
        #expect(AgentTerminal.submitProbe(for: "a\nb") == nil)
    }
}
