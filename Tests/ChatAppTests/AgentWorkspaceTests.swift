import AppKit
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
