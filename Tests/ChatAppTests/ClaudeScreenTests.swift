@testable import ChatApp
import Foundation
import Testing

/// Claude Code's menus, recap, notices, commands and Esc — screens and lines copied from a real Claude Code 2.1.330.
@MainActor @Suite struct ClaudeScreenTests {
    private let top = String(repeating: "▔", count: 60)

    @Test func mcpMenu() throws {
        let screen = [
            top,
            "  MCP servers",
            "  9 servers",
            "    claude.ai",
            "  ❯ ✔ claude.ai Claude Docs          8 tools",
            "    ✔ claude.ai Google Drive         15 tools",
            "    ✔ claude.ai Supabase             35 tools",
            "    → Show unused connectors         3 hidden",
            "  Learn more: https://code.claude.com/docs/en/mcp",
            "  ↑/↓ to navigate · Enter to view · Esc to close",
        ]
        let menu = try #require(ClaudeScreen.parse(screen))
        #expect(menu.title == "MCP servers")
        let rows = menu.lines.filter { $0.row != nil }
        #expect(rows.count == 5, "claude.ai heading, the three servers and Show unused")
        #expect(rows.first { $0.isSelected }?.text.contains("Claude Docs") == true)
        // Google Drive is one below the highlight.
        let drive = try #require(rows.first { $0.text.contains("Google Drive") }?.row)
        #expect(menu.keys(forRow: drive) == ClaudeKey.down + [0x0D])
        #expect(menu.keys.map(\.label) == ["↑", "↓", "View", "Close"])
    }

    /// /permissions with a long list, from a real Claude Code: its footer pushed off the bottom of the screen.
    @Test func aMenuWhoseFooterScrolledOff() throws {
        let screen = [
            top,
            "  Permissions  Recently blocked   Allow   Ask   Deny   Auto mode   Workspace",
            "  ╭──────────────────────────────╮",
            "  │ ⌕ Search…                    │",
            "  ╰──────────────────────────────╯",
            "    ↑ 4 more",
            "    Bash(npm install *)",
            "  ❯ Bash(python split_dataset/summarize.py -f",
            "      split_dataset/tf_idf/test_predictions_table_log_reg.csv)",
            "    ↓ 29 more",
        ]
        let menu = try #require(ClaudeScreen.parse(screen, cursorLine: "  ❯ Bash(python split_dataset/summarize.py -f"))
        #expect(menu.listFocused)
        #expect(menu.keys.map(\.label) == ["↑", "↓", "Select", "Close"])
    }

    @Test func focusStartsOnTheSearchBox() throws {
        let screen = [top, "  Permissions  Allow   Ask", "  │ ⌕ Search…  │", "  ❯ Add a new rule…", "    Bash(git init *)",
                      "  ↓ to navigate · ←/→ to switch · / to search · Esc to close"]
        let opening = try #require(ClaudeScreen.parse(screen, cursorLine: "  Permissions  Allow   Ask"))
        #expect(!opening.listFocused, "the first ↓ moves into the list without moving the highlight")
        let inList = try #require(ClaudeScreen.parse(screen, cursorLine: "  ❯ Add a new rule…"))
        #expect(inList.listFocused)
    }

    @Test func statusHasNoListJustText() throws {
        let screen = [top, "  Settings  Status   Config   Usage   Stats", "", "  Version:           2.1.330",
                      "  Model:             haiku (claude-haiku-5-5)", "  ←/→ to switch · Esc to close"]
        let menu = try #require(ClaudeScreen.parse(screen))
        #expect(menu.lines.allSatisfy { $0.row == nil })
        #expect(menu.keys.map(\.label) == ["←", "→", "Close"])
    }

    @Test func modelPickerIsAPromptWithItsExtraKey() throws {
        let screen = [
            top,
            "  Select model",
            "  Your pick is the default for new sessions. For other models, use --model.",
            "    1.  Default (recommended)  Opus 5.5 · Best for everyday, complex tasks",
            "    2.  Opus 5.5               For complex work and everyday tasks",
            "    3.  Sonnet 5.5             Most efficient for simpler tasks",
            "  ❯ 5.  Haiku 5.5 ✔            Fastest for quick answers",
            "  ◐ Medium effort (default) ←/→ to adjust",
            "  s to use this session only · Enter to save · Esc to cancel",
        ]
        let prompt = try #require(ClaudePrompt.parse(screen))
        #expect(prompt.options.map(\.number) == [1, 2, 3, 5])
        #expect(prompt.extraKeys.map(\.label) == ["Use this session only"])
        #expect(prompt.extraKeys.first?.keys == Array("s".utf8))
    }

    @Test func themeListWithACheckmark() throws {
        let screen = [top, "  Theme", "  Choose the text style that looks best with your terminal", "  ❯ ✔ Auto (match terminal)",
                      "      Dark mode", "      Light mode", "  Enter to select · Esc to cancel"]
        let prompt = try #require(ClaudePrompt.parse(screen))
        #expect(prompt.options.map(\.label) == ["✔ Auto (match terminal)", "Dark mode", "Light mode"])
        #expect(prompt.keys(for: prompt.options[2]) == ClaudeKey.down + ClaudeKey.down + [0x0D])
    }

    @Test func claudesOwnFooterIsntAMenu() {
        let idle = ["⏺ ok", "──────────", "❯ ", "──────────", "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent"]
        #expect(ClaudeScreen.parse(idle) == nil)
        let working = ["✶ Thinking…", "──────────", "❯ ", "──────────", "  ⏵⏵ auto mode on · esc to interrupt"]
        #expect(ClaudeScreen.parse(working) == nil)
    }

    // MARK: Session file

    private func parse(_ lines: [String]) -> TranscriptParser {
        var parser = TranscriptParser()
        parser.feed(Data((lines.joined(separator: "\n") + "\n").utf8))
        return parser
    }

    @Test func recapSitsAboveTheNextPromptAndNoticesFold() {
        let parser = parse([
            #"{"type":"system","subtype":"informational","uuid":"n1","content":"notchman-bridge: hooks.json changed — reloaded (3 hooks)","level":"notice"}"#,
            #"{"type":"system","subtype":"informational","uuid":"n2","content":"\u001b[2mmod reloaded\u001b[22m","level":"notice"}"#,
            #"{"type":"system","subtype":"away_summary","uuid":"r1","content":"We're polishing the session view."}"#,
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"keep going"}}"#,
        ])
        let items = SessionItem.items(parser.entries)
        #expect(items.count == 3)
        if case .notices(_, let texts) = items[0] { #expect(texts == ["notchman-bridge: hooks.json changed — reloaded (3 hooks)", "mod reloaded"]) } else { Issue.record("notices first") }
        if case .recap(_, let text) = items[1] { #expect(text == "We're polishing the session view.") } else { Issue.record("then the recap") }
        if case .prompt(_, let text) = items[2] { #expect(text == "keep going") } else { Issue.record("then your prompt") }
    }

    @Test func slashCommandsAndWhatTheyPrinted() {
        let parser = parse([
            #"{"type":"user","uuid":"c1","message":{"role":"user","content":"<command-name>/compact</command-name>\n<command-message>compact</command-message>\n<command-args></command-args>"}}"#,
            #"{"type":"user","uuid":"c2","message":{"role":"user","content":"<local-command-stdout>\u001b[2mCompacted (ctrl+o to see full summary)\u001b[22m</local-command-stdout>"}}"#,
        ])
        #expect(parser.entries.map(\.kind) == [.command("/compact", output: "Compacted (ctrl+o to see full summary)")])
    }

    @Test func escBeforeClaudeAnswersTakesThePromptBack() {
        let parser = parse([
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"Write a 500 word essay about bridges."}}"#,
            #"{"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
        ])
        #expect(parser.entries.isEmpty)
        #expect(parser.withdrawnPrompt == "Write a 500 word essay about bridges.")
        #expect(parser.turnOpen == false)
        // Once Claude has done something, the prompt stays.
        let started = parse([
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"fix it"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"Looking."}]}}"#,
            #"{"type":"user","uuid":"u2","message":{"role":"user","content":"[Request interrupted by user]"}}"#,
        ])
        #expect(started.entries.count == 2 && started.withdrawnPrompt == nil)
    }

    @Test func claudesPlaceholderIsntAPrompt() {
        #expect(AgentTerminal.isPlaceholder("Try \"edit <filepath> to…\""))
        #expect(!AgentTerminal.isPlaceholder("Write a 500 word essay"))
    }

    @Test func atMentionWhereTheCursorIs() {
        let draft = "look at @Sh and fix it"
        let caret = draft.index(draft.startIndex, offsetBy: 11)  // right after "@Sh"
        let token = ComposerSuggestions.token(in: draft, caret: caret)
        #expect(token?.kind == .file && token?.query == "Sh")
        let suggestion = ComposerSuggestion(kind: .file, insert: "@Sources/Shelf.swift ", title: "Shelf.swift", detail: nil)
        #expect(ComposerSuggestions.apply(suggestion, to: draft, caret: caret) == "look at @Sources/Shelf.swift and fix it")
        #expect(ComposerSuggestions.token(in: draft) == nil, "with the cursor at the end, the last word isn't a mention")
    }
}
