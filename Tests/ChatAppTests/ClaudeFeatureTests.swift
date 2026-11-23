@testable import ChatApp
import Foundation
import Testing

/// Modes, background shells, panels, rewind, the plan and the message box's suggestions. Screens copied from a real
/// Claude Code 2.1.330 run.
@MainActor @Suite struct ClaudeFeatureTests {
    @Test func everyModeIsRead() {
        #expect(ClaudeMode.parse(["  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent"]) == "Auto mode")
        #expect(ClaudeMode.parse(["  ⏸ manual mode on · ? for shortcuts · ← 1 agent"]) == "Manual mode")
        #expect(ClaudeMode.parse(["  ⏵⏵ accept edits on (shift+tab to cycle) · ← 1 agent"]) == "Accept edits")
        #expect(ClaudeMode.parse(["  ⏸ plan mode on (shift+tab to cycle) · ← 1 agent"]) == "Plan mode")
        // While working, or with a shell running, the "(shift+tab to cycle)" hint goes away; the mode doesn't.
        #expect(ClaudeMode.parse(["  ⏵⏵ auto mode on · 1 shell · ← 1 agent · ↓ to manage"]) == "Auto mode")
        #expect(ClaudeMode.cycleKey == [0x1B, 0x5B, 0x5A], "Shift-Tab")
    }

    @Test func backgroundShellsFromTheFooter() {
        #expect(ClaudeFooter.shells(["  ⏵⏵ auto mode on · 1 shell · ← 1 agent · ↓ to manage"]) == 1)
        #expect(ClaudeFooter.shells(["  ⏵⏵ auto mode on · 3 shells"]) == 3)
        #expect(ClaudeFooter.shells(["  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent"]) == 0)
    }

    @Test func aTaskPanelBecomesButtons() throws {
        let screen = [
            "✻ Churned for 5s · done 9:40 PM · 1 shell still running",
            String(repeating: "▔", count: 40),
            "  Sleep for 40 seconds in background",
            "  shell",
            "  Status:   running",
            "  Command:  sleep 40",
            "",
            "  ← to go back · x to stop · Enter/Space to close · Esc to close",
        ]
        let panel = try #require(ClaudePanel.parse(screen))
        #expect(panel.lines.first == "Sleep for 40 seconds in background")
        #expect(panel.actions.map(\.label) == ["Go back", "Stop", "Close"])
        #expect(panel.actions.first { $0.label == "Stop" }?.keys == Array("x".utf8))
        #expect(ClaudePrompt.parse(screen) == nil, "a panel isn't a prompt")
    }

    @Test func theRewindList() throws {
        let screen = [
            String(repeating: "▔", count: 40),
            "  Rewind",
            "",
            "  Restore the code and/or conversation to the point before…",
            "",
            "    Use TodoWrite (or your task list tool) to make a 3-item plan for writing a haiku, mark the firs…",
            "    No code changes",
            "",
            "  ❯ (current)",
            "",
            "  Enter to continue · Esc to cancel",
        ]
        let prompt = try #require(ClaudePrompt.parse(screen))
        #expect(prompt.options.count == 2)
        #expect(prompt.options[0].label.hasPrefix("Use TodoWrite"))
        #expect(prompt.options[0].detail == "No code changes")
        #expect(prompt.options[1].label == "(current)" && prompt.options[1].isSelected)
        #expect(prompt.keys(for: prompt.options[0]) == [0x1B, 0x5B, 0x41, 0x0D], "up, then Return")
        #expect(prompt.title.first == "Rewind")
    }

    @Test func thePlanFollowsTodoWrite() {
        var parser = TranscriptParser()
        parser.feed(Data((#"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"TodoWrite","input":{"todos":[{"content":"Read the code","status":"completed"},{"content":"Fix it","status":"in_progress"},{"content":"Test it","status":"pending"}]}}]}}"# + "\n").utf8))
        #expect(parser.todos.map(\.title) == ["Read the code", "Fix it", "Test it"])
        #expect(parser.todos.map(\.status) == [.completed, .inProgress, .pending])
    }

    @Test func thePlanFollowsTaskCreateAndUpdate() {
        var parser = TranscriptParser()
        let lines = [
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"TaskCreate","input":{"subject":"Shared Gemini wrapper","description":"…"}}]}}"#,
            #"{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"Task #1 created successfully: Shared Gemini wrapper"}]}}"#,
            #"{"type":"assistant","uuid":"a2","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"TaskCreate","input":{"subject":"Schema migration"}}]}}"#,
            #"{"type":"user","uuid":"r2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"Task #2 created successfully: Schema migration"}]}}"#,
            #"{"type":"assistant","uuid":"a3","message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"TaskUpdate","input":{"taskId":"1","status":"in_progress"}}]}}"#,
        ]
        parser.feed(Data((lines.joined(separator: "\n") + "\n").utf8))
        #expect(parser.todos.map(\.id) == ["1", "2"])
        #expect(parser.todos.map(\.status) == [.inProgress, .pending])
    }

    @Test func suggestionsForSlashAndAt() {
        #expect(ComposerSuggestions.token(in: "/comp")?.kind == .command)
        #expect(ComposerSuggestions.token(in: "/compact now") == nil, "past the command name")
        #expect(ComposerSuggestions.token(in: "look at @Shelf")?.query == "Shelf")
        #expect(ComposerSuggestions.token(in: "email me@x.com") == nil, "an @ inside a word isn't a mention")
        let commands = ComposerSuggestions.suggestions(for: "/comp", folder: "/tmp", files: [])
        #expect(commands.first?.insert == "/compact ")
        let files = ComposerSuggestions.suggestions(for: "fix @shelfv", folder: "/tmp",
                                                    files: ["Sources/Apps/ShelfApp/ShelfView.swift", "README.md", "Sources/Shelf.swift"])
        #expect(files.first?.insert == "@Sources/Apps/ShelfApp/ShelfView.swift ")
        #expect(ComposerSuggestions.apply(files[0], to: "fix @shelfv") == "fix @Sources/Apps/ShelfApp/ShelfView.swift ")
    }

    @Test func yourCommandsAndSkillsAreListed() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "cmds-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base + "/commands/git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: base + "/skills/deploy", withIntermediateDirectories: true)
        try "---\ndescription: Ship it\n---\nbody".write(toFile: base + "/commands/git/ship.md", atomically: true, encoding: .utf8)
        try "---\nname: deploy\ndescription: \"Deploy the site\"\n---".write(toFile: base + "/skills/deploy/SKILL.md", atomically: true, encoding: .utf8)
        #expect(SlashCommands.commands(in: base + "/commands") == [.init(name: "git:ship", summary: "Ship it")])
        #expect(SlashCommands.skills(in: base + "/skills") == [.init(name: "deploy", summary: "Deploy the site")])
        try? FileManager.default.removeItem(atPath: base)
    }
}
