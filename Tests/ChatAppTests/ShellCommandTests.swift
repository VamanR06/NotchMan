@testable import ChatApp
import Foundation
import Testing

/// Which bits of Claude's replies read as commands you can ⌘-click to run.
@Suite struct ShellCommandTests {
    @Test func inlineCodeThatReadsAsACommand() {
        #expect(ShellCommand.inline("swift test") == "swift test")
        #expect(ShellCommand.inline("$ git status") == "git status")
        #expect(ShellCommand.inline("FOO=1 npm run dev") == "FOO=1 npm run dev")
        #expect(ShellCommand.inline("./scripts/build.sh --release") == "./scripts/build.sh --release")
    }

    @Test func namesAndCodeArentCommands() {
        #expect(ShellCommand.inline("git") == nil)               // a name, most likely
        #expect(ShellCommand.inline("SessionView.swift") == nil)
        #expect(ShellCommand.inline("let x = 1") == nil)
        #expect(ShellCommand.inline("isRunning") == nil)
    }

    @Test func shellBlocks() {
        #expect(ShellCommand.block("swift build\nswift test", language: "bash") == "swift build\nswift test")
        #expect(ShellCommand.block("# build\nmake", language: "sh") == "make")
        // In a console block only the prompted lines are commands; the rest is output.
        #expect(ShellCommand.block("$ ls\nREADME.md\n$ pwd", language: "console") == "ls\npwd")
    }

    @Test func otherBlocks() {
        #expect(ShellCommand.block("let x = 1", language: "swift") == nil)
        #expect(ShellCommand.block("npm install\nnpm test", language: nil) == "npm install\nnpm test")
        #expect(ShellCommand.block("Some prose\nnpm test", language: nil) == nil)
    }

    @Test func linksRoundTrip() throws {
        let command = "git log --oneline -5 | grep \"fix #12\""
        let url = try #require(ShellCommand.link(for: command))
        #expect(ShellCommand.command(from: url) == command)
        #expect(ShellCommand.command(from: URL(string: "https://example.com")!) == nil)
    }
}

@MainActor @Suite struct PromptRailTests {
    @Test func currentPromptIsTheOneAboveWhatsOnScreen() {
        let items: [SessionItem] = [
            .prompt(id: "p1", "first"), .reply(id: "r1", "a"),
            .prompt(id: "p2", "second"), .steps(id: "s2", []), .reply(id: "r2", "b"),
        ]
        #expect(PromptMark.current(visible: ["r2"], in: items) == "p2")
        #expect(PromptMark.current(visible: ["r1", "p2"], in: items) == "p1")
        #expect(PromptMark.current(visible: [], in: items) == nil)
    }

    @Test func titleIsTheFirstLine() {
        #expect(PromptMark(id: "x", text: "fix   the\nbuild please").title == "fix the")
    }
}
