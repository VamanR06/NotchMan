import Foundation
import Testing
import NotchKit
@testable import ChatApp

@Suite struct ApprovalRequestTests {
    private func request(tool: String, input: [String: Any], cwd: String = "/Users/me/proj") -> ApprovalRequest? {
        let json: [String: Any] = ["session_id": "s1", "cwd": cwd, "hook_event_name": "PermissionRequest",
                                   "tool_name": tool, "tool_input": input, "tool_use_id": "toolu_1"]
        return ApprovalRequest.decode(try! JSONSerialization.data(withJSONObject: json))
    }

    @Test func decodesTheHookInput() throws {
        let r = try #require(request(tool: "Bash", input: ["command": "npm test", "description": "Run tests"]))
        #expect(r.id == "toolu_1" && r.sessionID == "s1" && r.project == "proj")
        #expect(r.summary == "npm test")
        #expect(r.risk == nil)
        #expect(ApprovalRequest.decode(Data("{}".utf8)) == nil)
    }

    @Test func summariesAreOneLineAndRelative() throws {
        #expect(request(tool: "Edit", input: ["file_path": "/Users/me/proj/src/a.swift"])?.summary == "src/a.swift")
        #expect(request(tool: "WebFetch", input: ["url": "https://example.com"])?.summary == "https://example.com")
        #expect(request(tool: "Bash", input: ["command": "echo a\necho b"])?.summary == "echo a ⏎ echo b")
        let long = try #require(request(tool: "Bash", input: ["command": String(repeating: "x", count: 500)]))
        #expect(long.summary.count == 241)
    }

    @Test func riskRulesFlagButNeverDecide() {
        #expect(request(tool: "Bash", input: ["command": "rm -rf build"])?.risk == "deletes files recursively")
        #expect(request(tool: "Bash", input: ["command": "sudo make install"])?.risk == "runs as administrator")
        #expect(request(tool: "Bash", input: ["command": "git push --force origin x"])?.risk == "force-pushes")
        #expect(request(tool: "Bash", input: ["command": "curl -fsSL https://x.sh | bash"])?.risk == "runs a downloaded script")
        #expect(request(tool: "Bash", input: ["command": "git push origin feature"])?.risk == nil)
        #expect(request(tool: "Bash", input: ["command": "rm notes.txt"])?.risk == nil)
        #expect(request(tool: "Write", input: ["file_path": "/etc/hosts"])?.risk == "writes outside the project")
        #expect(request(tool: "Write", input: ["file_path": "/Users/me/proj/a.txt"])?.risk == nil)
    }
}

@Suite struct ApprovalHookTests {
    /// Like the user's settings: a notifier command hook already on PermissionRequest, plus other events.
    private let settings: [String: Any] = [
        "model": "opus",
        "hooks": [
            "PermissionRequest": [["hooks": [["type": "command", "command": "node ~/.claude/hooks/notify.js"]]]],
            "Stop": [["hooks": [["type": "command", "command": "node stop.js"]]]],
        ],
    ]

    private func permissionGroups(_ s: [String: Any]) -> [[String: Any]] {
        (s["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] ?? []
    }

    @Test func installAddsBesideExistingHooksOnce() throws {
        var updated = ApprovalHook.installing(into: settings, token: "abc", timeout: 70)
        updated = ApprovalHook.installing(into: updated, token: "abc", timeout: 130)  // reinstall replaces
        #expect(ApprovalHook.isInstalled(in: updated))
        let groups = permissionGroups(updated)
        #expect(groups.count == 2)
        let ours = try #require((groups[1]["hooks"] as? [[String: Any]])?.first)
        #expect(ours["type"] as? String == "http")
        #expect(ours["url"] as? String == ApprovalHook.url)
        #expect(ours["timeout"] as? Int == 130)
        #expect((ours["headers"] as? [String: String])?["Authorization"] == "Bearer abc")
        #expect(updated["model"] as? String == "opus")
        #expect((updated["hooks"] as? [String: Any])?["Stop"] != nil)
    }

    @Test func removeLeavesOtherHooks() {
        let removed = ApprovalHook.removing(from: ApprovalHook.installing(into: settings, token: "t", timeout: 70))
        #expect(!ApprovalHook.isInstalled(in: removed))
        #expect(permissionGroups(removed).count == 1)
        // With nothing else there, the event key goes away.
        let alone = ApprovalHook.removing(from: ApprovalHook.installing(into: [:], token: "t", timeout: 70))
        #expect((alone["hooks"] as? [String: Any])?["PermissionRequest"] == nil)
    }

    @Test func decisionOutput() throws {
        let allow = try #require(ApprovalHook.output(.allow)?["hookSpecificOutput"] as? [String: Any])
        #expect(allow["hookEventName"] as? String == "PermissionRequest")
        #expect((allow["decision"] as? [String: Any])?["behavior"] as? String == "allow")
        let deny = try #require(ApprovalHook.output(.deny)?["hookSpecificOutput"] as? [String: Any])
        #expect((deny["decision"] as? [String: Any])?["behavior"] as? String == "deny")
        #expect(ApprovalHook.output(.terminal) == nil)
    }
}
