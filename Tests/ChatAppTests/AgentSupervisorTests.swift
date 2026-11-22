@testable import ChatApp
import Foundation
import Testing

/// When a working agent looks stuck: plain rules over its current turn.
@Suite struct StuckRulesTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func prompt() -> TranscriptEntry { TranscriptEntry(id: UUID().uuidString, time: now, kind: .prompt("go")) }

    private func bash(_ command: String, failed: Bool = false, finished: Bool = true, at time: Date? = nil) -> TranscriptEntry {
        var call = ToolCall(id: UUID().uuidString, name: "Bash", summary: command, detail: .command(command))
        if finished { call.result = failed ? "error" : "ok" }
        call.isError = failed
        return TranscriptEntry(id: UUID().uuidString, time: time ?? now, kind: .tool(call))
    }

    private func edit(_ path: String) -> TranscriptEntry {
        var call = ToolCall(id: UUID().uuidString, name: "Edit", summary: path, detail: .edit(path: path, old: "a", new: "b"))
        call.result = "ok"
        return TranscriptEntry(id: UUID().uuidString, time: now, kind: .tool(call))
    }

    @Test func theSameCallFailingThreeTimes() {
        let entries = [prompt(), bash("swift test", failed: true), edit("/a.swift"), bash("swift test", failed: true),
                       edit("/a.swift"), bash("swift  test", failed: true)]
        #expect(StuckRules.signal(entries: entries, lastWrite: now, now: now) == StuckSignal(kind: .failing, subject: "`swift test`"))
    }

    @Test func failuresInAnEarlierTurnDontCount() {
        let entries = [prompt(), bash("make", failed: true), bash("make", failed: true), prompt(), bash("make", failed: true)]
        #expect(StuckRules.signal(entries: entries, lastWrite: now, now: now) == nil)
    }

    @Test func repeatingWithoutEditsIsALoop() {
        let entries = [prompt()] + (0..<4).flatMap { _ in [bash("git status"), bash("ls")] }
        #expect(StuckRules.signal(entries: entries, lastWrite: now, now: now)?.kind == .looping)
        // With edits in between it's progress.
        let working = [prompt()] + (0..<4).flatMap { index in [bash("swift build"), edit("/f\(index).swift")] }
        #expect(StuckRules.signal(entries: working, lastWrite: now, now: now) == nil)
    }

    @Test func editingOneFileOverAndOver() {
        let entries = [prompt()] + (0..<8).map { _ in edit("/Sources/ShelfView.swift") }
        #expect(StuckRules.signal(entries: entries, lastWrite: now, now: now)
            == StuckSignal(kind: .churning, subject: "ShelfView.swift"))
    }

    @Test func aCallRunningForFiveMinutes() {
        let entries = [prompt(), bash("npm run dev", finished: false, at: now.addingTimeInterval(-301))]
        #expect(StuckRules.signal(entries: entries, lastWrite: now, now: now)?.kind == .hung)
        let recent = [prompt(), bash("npm run dev", finished: false, at: now.addingTimeInterval(-60))]
        #expect(StuckRules.signal(entries: recent, lastWrite: now, now: now) == nil)
    }

    @Test func quietForFiveMinutes() {
        let entries = [prompt(), bash("ls")]
        #expect(StuckRules.signal(entries: entries, lastWrite: now.addingTimeInterval(-301), now: now)?.kind == .silent)
        #expect(StuckRules.signal(entries: entries, lastWrite: now.addingTimeInterval(-30), now: now) == nil)
    }

    @Test func evidenceIsDataAboutTheTurn() {
        let entries = [prompt(), bash("swift test", failed: true)]
        let text = StuckRules.evidence(StuckSignal(kind: .failing, subject: "`swift test`"), entries: entries)
        #expect(text.contains("swift test") && text.contains("failed") && text.contains("keeps failing"))
    }
}

@Suite struct LimitLabelTests {
    @Test func shortLabelsFitTheTopRow() {
        #expect(ClaudeLimitWindow(label: "Current week (all models)", percent: 45, resetsText: "").shortLabel == "Week")
        #expect(ClaudeLimitWindow(label: "Current session", percent: 5, resetsText: "").shortLabel == "Session")
        #expect(ClaudeLimitWindow(label: "Current week (Sonnet only)", percent: 5, resetsText: "").shortLabel == "Week")
    }
}

/// ChatGPT answers through `codex exec --json`.
@Suite struct CodexReaderTests {
    @Test func readsTheAgentMessage() {
        var reader = CodexCLI.StreamReader()
        let changed = reader.feed("""
            {"type":"thread.started","thread_id":"x"}
            {"type":"turn.started"}
            {"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"thinking"}}
            {"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Paris."}}
            {"type":"turn.completed","usage":{}}

            """)
        #expect(changed)
        #expect(reader.text == "Paris.")
        #expect(reader.result == "Paris.")
    }

    @Test func aFailedTurnSaysWhy() {
        var reader = CodexCLI.StreamReader()
        _ = reader.feed(#"{"type":"turn.failed","error":{"message":"not signed in"}}"# + "\n")
        #expect(reader.result == "ChatGPT couldn't answer: not signed in")
    }

    @Test func runsReadOnlyWithoutASession() {
        let arguments = CodexCLI.askArguments(question: "capital of France?", frontmostApp: nil)
        #expect(arguments.starts(with: ["exec", "--json"]))
        #expect(arguments.contains("--ephemeral") && arguments.contains("read-only"))
        #expect(arguments.last?.contains("capital of France?") == true)
    }
}
