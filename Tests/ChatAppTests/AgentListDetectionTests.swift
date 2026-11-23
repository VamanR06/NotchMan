import Testing
@testable import ChatApp

@MainActor @Suite struct AgentListDetectionTests {
    /// Captured from `claude attach` after pressing ← (Claude Code 2.1.280).
    private let agentList = """
     ▐▛███▛█   Claude Code v2.1.280
    ▝▜██████▀  Opus 5.5 · ~/GitHub/Research/coachbot
      ▝▝ ▝▝    1 awaiting input · 2 working · 34 completed
    Needs input
    ✻ colab-coachbot-tester                     check `terminated` field in you…         19d
    Working
    ✻ notchman-engine-setup                     investigating ← key behavior in…         16h
    ────────────────────────────────────────────────────────────────────────────────
    ❯ describe a task for a new session
    ────────────────────────────────────────────────────────────────────────────────
      enter to return · space to reply · ctrl+x to delete · ? for shortcuts
    """

    /// The session itself (before ←).
    private let session = """
    ✻ Crunched for 1m 25s · done 10:26 AM
    ─────────────────────────────────────────────────────── chat nodes debug messaging ─
    ❯ rewrite the coacher prompt for me
    ────────────────────────────────────────────────────────────────────────────────
      ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent
    """

    /// An empty input box, the caret right after `❯ `.
    private let emptyPrompt = [
        "✻ Crunched for 1m 25s · done 10:26 AM",
        "────────────────────────────────────────",
        "❯ ",
        "────────────────────────────────────────",
        "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent",
    ]

    @Test func leftArrowLeavesFromAnEmptyPrompt() {
        #expect(AgentTerminal.caretAtPromptStart(lines: emptyPrompt, cursorRow: 2, cursorColumn: 2))
    }

    @Test func leftArrowLeavesFromTheStartOfTypedText() {
        var lines = emptyPrompt
        lines[2] = "❯ rewrite the coacher prompt"
        #expect(AgentTerminal.caretAtPromptStart(lines: lines, cursorRow: 2, cursorColumn: 2))
    }

    @Test func leftArrowMovesTheCaretWithinTypedText() {
        var lines = emptyPrompt
        lines[2] = "❯ rewrite the coacher prompt"
        #expect(!AgentTerminal.caretAtPromptStart(lines: lines, cursorRow: 2, cursorColumn: 12))
    }

    @Test func leftArrowIsLeftAloneOutsideTheInputBox() {
        // A menu Claude draws ("❯ 1. Yes") has no rule above it; the cursor elsewhere isn't on the prompt.
        let menu = ["Do you want to proceed?", "❯ 1. Yes", "  2. No"]
        #expect(!AgentTerminal.caretAtPromptStart(lines: menu, cursorRow: 1, cursorColumn: 2))
        #expect(!AgentTerminal.caretAtPromptStart(lines: emptyPrompt, cursorRow: 0, cursorColumn: 0))
        #expect(!AgentTerminal.caretAtPromptStart(lines: emptyPrompt, cursorRow: 9, cursorColumn: 0))
    }

    @Test func recognizesClaudeCodesAgentList() {
        #expect(AgentTerminal.isClaudeAgentList(agentList))
        #expect(!AgentTerminal.isClaudeAgentList(session))
        #expect(!AgentTerminal.isClaudeAgentList(""))
    }
}
