import AppKit
import SwiftUI
import Testing
@testable import ChatApp

@MainActor @Suite struct AgentWorkspaceTests {
    private let agent = ClaudeAgent(id: "s1", shortID: "abc", name: "Test", cwd: "/tmp", kind: .background,
                                    state: "working", status: "busy", startedAt: nil)

    @Test func shellOpensInTheAgentsFolderAndExitClosesItsTab() async throws {
        let workspace = AgentTerminal(agent: agent)
        let shell = workspace.addShell()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 380), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = shell.session.view
        #expect(workspace.selected == .shell(shell.id))
        try await Task.sleep(for: .milliseconds(800))  // let zsh start
        shell.session.view.send(txt: "echo \"IN_$(pwd)\"\r")
        var screen = ""
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            screen = shell.session.screenText
            if screen.contains("IN_/tmp") || screen.contains("IN_/private/tmp") { break }
        }
        #expect(screen.contains("IN_/tmp") || screen.contains("IN_/private/tmp"), "got: \(screen)")
        shell.session.view.send(txt: "exit\r")
        for _ in 0..<30 where !workspace.shells.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(workspace.shells.isEmpty, "typing exit closes the tab")
        #expect(workspace.selected == .claude)
    }

    @Test func tabsSelectionAndSplit() {
        let workspace = AgentTerminal(agent: agent)
        let one = workspace.addShell()
        let two = workspace.addShell()
        #expect(workspace.shells.map(\.number) == [1, 2])
        #expect(workspace.selected == .shell(two.id))
        workspace.split = true
        #expect(workspace.splitShell?.id == two.id)
        workspace.selected = .claude
        #expect(workspace.splitShell?.id == two.id, "split keeps showing the latest shell")
        workspace.selected = .shell(one.id)
        workspace.closeShell(one.id)
        #expect(workspace.selected == .shell(two.id), "closing selects the neighbour")
        workspace.closeShell(two.id)
        #expect(workspace.selected == .claude && !workspace.split, "no shells: back to Claude, unsplit")
        // Numbers keep counting up so tabs aren't confusable.
        #expect(workspace.addShell().number == 3)
        workspace.stop()
        #expect(workspace.shells.isEmpty)
    }
}

@Suite struct SplitLayoutTests {
    @Test func bothPanesGetRealHeight() {
        let (top, bottom) = SplitLayout.heights(total: 400, ratio: 0.6)
        #expect(abs(top - 234) < 0.5 && abs(bottom - 156) < 0.5)
        #expect(top + bottom + SplitLayout.handleHeight == 400)
    }

    @Test func shellNeverShrinksBelowTheMinimum() {
        let (top, bottom) = SplitLayout.heights(total: 400, ratio: 0.95)
        #expect(bottom == SplitLayout.minimumPane)
        #expect(top + bottom + SplitLayout.handleHeight == 400)
        #expect(SplitLayout.heights(total: 400, ratio: 0.05).top == SplitLayout.minimumPane)
    }
}

/// Regression: split, then close the shell → Claude's terminal must still be on screen.
@MainActor @Suite(.serialized) struct WorkspaceLayoutTests {
    @Test func closingTheSplitShellKeepsClaudeVisible() async throws {
        let agent = ClaudeAgent(id: "s1", shortID: "abc", name: "Test", cwd: "/tmp", kind: .background,
                                state: "working", status: "busy", startedAt: nil)
        let workspace = AgentTerminal(agent: agent)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 450), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AgentTerminalScreen(app: ChatApp(), terminal: workspace)
            .frame(width: 720, height: 450))

        func settle() async throws {
            for _ in 0..<5 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(60))
            }
        }

        let shell = workspace.addShell()
        workspace.split = true
        try await settle()
        #expect(workspace.claude.view.window === window)
        #expect(shell.session.view.window === window)
        #expect(shell.session.view.frame.height > 100, "split shell has real height")

        workspace.closeShell(shell.id)   // back to a single Claude pane
        try await settle()
        #expect(!workspace.split && workspace.selected == .claude)
        #expect(workspace.claude.view.window === window, "Claude terminal is still on screen")
        #expect(workspace.claude.view.frame.height > 300, "and fills the pane: \(workspace.claude.view.frame)")
        workspace.stop()
        window.close()
    }
}
