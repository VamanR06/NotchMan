import Foundation
import Testing
import NotchKit
@testable import ChatApp

@MainActor @Suite(.serialized) struct ApprovalAlwaysTests {
    private let bashRule: [String: Any] = [
        "type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test"]], "behavior": "allow",
        "destination": "localSettings",
    ]

    @Test func alwaysUsesClaudeCodesOwnSuggestion() throws {
        let always = try #require(AlwaysAllow.from(suggestions: [bashRule], tool: "Bash"))
        #expect(always.label == "Always allow “npm test”")
        #expect(always.entry?["destination"] as? String == "localSettings")
        let output = try #require(ApprovalHook.output(.always, always: always)?["hookSpecificOutput"] as? [String: Any])
        let decision = try #require(output["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        let updates = try #require(decision["updatedPermissions"] as? [[String: Any]])
        #expect(updates.count == 1 && updates[0]["type"] as? String == "addRules", "the suggestion goes back as it came")
    }

    @Test func editsWithoutASuggestionAcceptEditsForTheSession() throws {
        let always = try #require(AlwaysAllow.from(suggestions: [], tool: "Edit"))
        #expect(always.label == "Accept edits this session")
        #expect(always.entry?["mode"] as? String == "acceptEdits" && always.entry?["destination"] as? String == "session")
        #expect(AlwaysAllow.from(suggestions: [], tool: "Bash") == nil, "no Always without something to remember")
    }

    @Test func plainAllowAddsNoRule() throws {
        let always = try #require(AlwaysAllow.from(suggestions: [bashRule], tool: "Bash"))
        let output = try #require(ApprovalHook.output(.allow, always: always)?["hookSpecificOutput"] as? [String: Any])
        #expect((output["decision"] as? [String: Any])?["updatedPermissions"] == nil)
    }

    @Test func requestsReadTheirSuggestions() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "session_id": "s1", "cwd": "/repo", "tool_name": "Bash", "tool_input": ["command": "npm test"],
            "permission_suggestions": [bashRule],
        ])
        let request = try #require(ApprovalRequest.decode(body))
        #expect(request.always?.label == "Always allow “npm test”" && request.action == "Run command")
    }

    @Test func toolsHavePlainNames() {
        #expect(ApprovalRequest.action(for: "Write") == "Write file")
        #expect(ApprovalRequest.action(for: "mcp__github__create_issue") == "Create issue")
        #expect(ApprovalRequest.action(for: "Custom") == "Custom")
    }

    // MARK: Answered in the terminal

    private func agent(_ state: String) -> ClaudeAgent {
        ClaudeAgent(id: "s1", shortID: "abc", name: "fix-build", cwd: "/repo", kind: .background, state: state,
                    status: state == "working" ? "busy" : "idle", startedAt: Date())
    }

    private func pending(_ app: ChatApp, monitor: ClaudeAgentsMonitor) async throws -> Task<HookServer.Response, Never> {
        let body = try JSONSerialization.data(withJSONObject: [
            "session_id": "s1", "cwd": "/repo", "tool_name": "Bash", "tool_input": ["command": "npm test"],
        ])
        let task = Task { await app.handlePermissionRequest(body) }
        for _ in 0..<100 where app.approvals.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        return task
    }

    @Test func answeringInTheTerminalClearsTheChip() async throws {
        let monitor = ClaudeAgentsMonitor(defaults: UserDefaults(suiteName: "notchman.tests.approvals.settle")!)
        monitor.apply([agent("working")], now: Date())
        let app = ChatApp()
        app.useAgentMonitor(monitor)
        let task = try await pending(app, monitor: monitor)
        #expect(app.approvals.count == 1)

        monitor.apply([agent("blocked")], now: Date())  // waiting on the permission prompt
        app.settleAnsweredApprovals()
        #expect(app.approvals.count == 1)
        monitor.apply([agent("working")], now: Date())  // answered in its terminal, and on it goes
        app.settleAnsweredApprovals()
        #expect(app.approvals.isEmpty, "the chip goes")
        let response = await task.value
        #expect(response.body.isEmpty, "NotchMan doesn't answer a request the terminal already answered")
    }

    @Test func theBridgeSeeingTheToolRunClearsItToo() async throws {
        let monitor = ClaudeAgentsMonitor(defaults: UserDefaults(suiteName: "notchman.tests.approvals.bridge")!)
        monitor.apply([agent("working")], now: Date())
        let app = ChatApp()
        app.useAgentMonitor(monitor)
        let task = try await pending(app, monitor: monitor)
        app.receive(SessionSignal(event: "tool.done", session: "s1", tool: "Read"))
        #expect(app.approvals.count == 1, "a different tool")
        app.receive(SessionSignal(event: "tool.done", session: "s1", tool: "Bash"))
        #expect(app.approvals.isEmpty)
        _ = await task.value
    }

    @Test func aFreshRequestIsntClearedByAStaleDone() async throws {
        let monitor = ClaudeAgentsMonitor(defaults: UserDefaults(suiteName: "notchman.tests.approvals.stale")!)
        monitor.apply([agent("done")], now: Date())
        let app = ChatApp()
        app.useAgentMonitor(monitor)
        let task = try await pending(app, monitor: monitor)
        app.settleAnsweredApprovals()
        #expect(app.approvals.count == 1, "the list hasn't caught up yet")
        app.settleAnsweredApprovals(now: Date().addingTimeInterval(10))
        #expect(app.approvals.isEmpty, "a turn that's really over")
        _ = await task.value
    }

    // MARK: Ready

    @Test func openingASessionClearsReady() {
        let app = ChatApp()
        app.useUnseenForTesting(["s1", "s2"])
        app.markSeen(agent("done"))
        #expect(app.unseenAgents == ["s2"])
    }

    // MARK: Notifications

    @Test func approvalNotificationsCanBeAnsweredInPlace() throws {
        var request = try #require(ApprovalRequest.decode(try JSONSerialization.data(withJSONObject: [
            "session_id": "s1", "cwd": "/repo", "tool_name": "Bash", "tool_input": ["command": "rm -rf build"],
            "permission_suggestions": [bashRule],
        ])))
        request.always = AlwaysAllow.from(suggestions: [bashRule], tool: "Bash")
        let note = AgentNotifications.approval(request, agentName: "fix-build")
        #expect(note.title == "fix-build · Run command" && note.body == "rm -rf build")
        #expect(note.subtitle == "⚠ Deletes files recursively")
        #expect(note.actions.map(\.id) == ["allow", "always", "deny"] && note.urgency == .urgent)
        #expect(note.id == "approval:" + request.id, "withdrawn by id once answered anywhere")
    }

    @Test func sessionNotificationsSayWhatClaudeSaid() {
        let finished = AgentNotifications.finished(agent("done"), said: "All 42 tests pass.")
        #expect(finished.title == "fix-build finished" && finished.body == "All 42 tests pass.")
        #expect(finished.urgency == .quiet && finished.id == "agent:s1")
        let waiting = AgentNotifications.needsYou(agent("blocked"), said: "Which branch?")
        #expect(waiting.id == finished.id, "one per session: a later one replaces it")
        #expect(waiting.actions.first?.textInput != nil, "reply right from the notification")
        #expect(AgentNotifications.firstLine("## Done\n\n**All** tests `pass`.") == "Done")
        #expect(AgentNotifications.firstLine("```swift\ncode\n```\nFixed the build.") == "code")
    }
}
