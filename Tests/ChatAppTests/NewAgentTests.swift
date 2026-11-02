import Foundation
import Testing
@testable import ChatApp

@MainActor @Suite struct NewAgentTests {
    @Test func startsInTheChosenMode() {
        #expect(ClaudeAgentsMonitor.dispatchArguments(prompt: "Fix the build", mode: .plan)
                == ["--bg", "--permission-mode", "plan", "Fix the build"])
        #expect(ClaudeAgentsMonitor.dispatchArguments(prompt: "x", mode: .acceptEdits)[2] == "acceptEdits")
    }

    @Test func worktreesCountAsTheirRepo() {
        #expect(ClaudeAgentsMonitor.projectFolder("/Users/me/GitHub/NotchMan/.claude/worktrees/new-agent-mode")
                == "/Users/me/GitHub/NotchMan")
        #expect(ClaudeAgentsMonitor.projectFolder("/Users/me/GitHub/NotchMan") == "/Users/me/GitHub/NotchMan")

        let monitor = ClaudeAgentsMonitor(defaults: UserDefaults(suiteName: "notchman.tests.newagent")!)
        let now = Date()
        monitor.apply([
            ClaudeAgent(id: "1", shortID: "1", name: "a", cwd: "/r/NotchMan/.claude/worktrees/one", kind: .background,
                        state: "working", status: "busy", startedAt: now),
            ClaudeAgent(id: "2", shortID: "2", name: "b", cwd: "/r/JobManager", kind: .background,
                        state: "working", status: "busy", startedAt: now.addingTimeInterval(-60)),
            ClaudeAgent(id: "3", shortID: "3", name: "c", cwd: "/r/NotchMan", kind: .interactive,
                        state: "working", status: "busy", startedAt: now.addingTimeInterval(-120)),
        ], now: now)
        #expect(monitor.recentFolders == ["/r/NotchMan", "/r/JobManager"])
    }

    @Test func remembersTheLastMode() {
        let defaults = UserDefaults(suiteName: "notchman.tests.newagent.mode")!
        defaults.removePersistentDomain(forName: "notchman.tests.newagent.mode")
        let monitor = ClaudeAgentsMonitor(defaults: defaults)
        #expect(monitor.newAgentMode == .plan)
        monitor.newAgentMode = .auto
        #expect(ClaudeAgentsMonitor(defaults: defaults).newAgentMode == .auto)
    }
}
