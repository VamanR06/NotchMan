import AppKit
import Testing
@testable import ChatApp

@MainActor @Suite struct AgentTerminalTests {
    private let agent = ClaudeAgent(id: "s1", shortID: "abc", name: "Test", cwd: "/tmp", kind: .background,
                                    state: "working", status: "busy", startedAt: nil)

    @Test func runsALoginShellAndReportsExit() async throws {
        let terminal = AgentTerminal(agent: agent)
        // A window gives the view a real size, like the notch panel does.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 380), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = terminal.view
        terminal.run("cd /tmp && echo \"NOTCHMAN_OK $TERM $(pwd)\" && command -v zsh")
        #expect(terminal.isRunning)
        for _ in 0..<50 where terminal.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!terminal.isRunning, "process exit should be reported")
        let text = terminal.screenText
        #expect(text.contains("NOTCHMAN_OK xterm-256color /tmp") || text.contains("NOTCHMAN_OK xterm-256color /private/tmp"))
        #expect(text.contains("/bin/zsh"), "login shell PATH should resolve commands")
        _ = window
    }

    @Test func stopEndsTheProcess() async throws {
        let terminal = AgentTerminal(agent: agent)
        terminal.run("sleep 30")
        #expect(terminal.isRunning)
        terminal.stop()
        #expect(!terminal.isRunning)
    }
}
