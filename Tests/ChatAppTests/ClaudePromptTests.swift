@testable import ChatApp
import Testing

/// Claude Code's prompts, read off its screen. The screens are copied from a real Claude Code 2.1.330 run.
@MainActor @Suite struct ClaudePromptTests {
    private let trust = [
        "──────────────────────────────────────────────────",
        " Accessing workspace:",
        "",
        " /Users/me/tmp/trustprobe",
        "",
        " Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known",
        " open source project, or work from your team). If not, take a moment to review what's in this folder",
        " first.",
        "",
        " Claude Code'll be able to read, edit, and execute files here.",
        "",
        " Security guide",
        "",
        " ❯ No, exit",
        "   Yes, I trust this folder",
        "",
        " Enter to confirm · Esc to cancel",
    ]

    private let question = [
        "❯ Use the AskUserQuestion tool to ask me which color I like, with options red, green and blue.",
        "──────────────────────────────────────────────────",
        " ☐ Color ",
        "",
        "Which color do you like?",
        "",
        "❯ 1. Red",
        "     Red",
        "  2. Green",
        "     Green",
        "  3. Blue",
        "     The calm one",
        "  4. Type something.",
        "──────────────────────────────────────────────────",
        "  5. Chat about this",
        "",
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
    ]

    @Test func readsTheTrustPrompt() throws {
        let prompt = try #require(ClaudePrompt.parse(trust))
        #expect(prompt.options.map(\.label) == ["No, exit", "Yes, I trust this folder"])
        #expect(prompt.options[0].isSelected && prompt.options[0].number == nil)
        #expect(prompt.title.first == "Accessing workspace:")
        #expect(prompt.title.contains { $0.contains("Quick safety check") })
        // No numbers: down from the highlighted option, then Return.
        #expect(prompt.keys(for: prompt.options[1]) == [0x1B, 0x5B, 0x42, 0x0D])
        #expect(prompt.keys(for: prompt.options[0]) == [0x0D])
    }

    @Test func readsAQuestionClaudeAsked() throws {
        let prompt = try #require(ClaudePrompt.parse(question))
        #expect(prompt.options.map(\.label) == ["Red", "Green", "Blue", "Type something.", "Chat about this"])
        #expect(prompt.options.map(\.number) == [1, 2, 3, 4, 5])
        #expect(prompt.title == ["Color", "Which color do you like?"])
        #expect(prompt.options[0].detail == nil, "a description that only repeats the label is dropped")
        #expect(prompt.options[2].detail == "The calm one")
        #expect(prompt.options[3].isTextEntry)
        // Pressing the number answers.
        #expect(prompt.keys(for: prompt.options[1]) == Array("2".utf8))
    }

    @Test func claudesOwnInputBoxIsntAPrompt() {
        let idle = ["⏺ You picked green.", "", "✻ Brewed for 2s · done 9:23 PM", "", "──────────", "❯ ", "──────────",
                    "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent"]
        #expect(ClaudePrompt.parse(idle) == nil)
        #expect(ClaudeMode.parse(idle) == "Auto mode")
    }

    @Test func blankCellsReadAsSpaces() {
        // Claude Code skips over blank space with cursor moves; the terminal reports those cells as NULs.
        #expect(TerminalSession.text(of: "\0❯\0No,\0exit\0\0\0") == " ❯ No, exit")
    }

    @Test func liveReplyStopsAtClaudesStatusAndYourNextPrompt() {
        let screen = ["⏺ You picked green.", "", "✻ Brewed for 2s · done 9:23 PM", "", "❯ Write three paragraphs.",
                      "──────────", "❯ ", "──────────"]
        #expect(AgentTerminal.liveReply(screen) == "You picked green.")
        let answered = ["⏺ Answered Claude's questions:", "  ⎿  · Which color do you like? → Green", "──────────", "❯ "]
        #expect(AgentTerminal.liveReply(answered) == nil)
    }
}
