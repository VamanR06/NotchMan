import Foundation
import NotchKit
import Testing
@testable import ChatApp

@MainActor @Suite struct ClaudeBridgeTests {
    private let folder = URL(fileURLWithPath: "/Users/me/Library/Application Support/NotchMan/claude-bridge")

    @Test func installingKeepsYourOtherSettingsAndPluginFolders() {
        let settings: [String: Any] = ["hooks": ["Stop": []], "env": ["CLAUDE_CODE_PLUGIN_DIRS": "/my/plugin", "FOO": "1"]]
        let installed = ClaudeBridge.installing(into: settings, folder: folder)
        #expect(ClaudeBridge.pluginDirs(in: installed) == ["/my/plugin", folder.path])
        #expect((installed["env"] as? [String: Any])?["FOO"] as? String == "1")
        #expect(installed["hooks"] != nil)
        // Installing twice doesn't add it twice.
        #expect(ClaudeBridge.pluginDirs(in: ClaudeBridge.installing(into: installed, folder: folder)).count == 2)
    }

    @Test func removingLeavesNothingBehind() {
        let installed = ClaudeBridge.installing(into: [:], folder: folder)
        let removed = ClaudeBridge.removing(from: installed, folder: folder)
        #expect(removed["env"] == nil, "no empty env left over")
        let shared = ClaudeBridge.installing(into: ["env": ["CLAUDE_CODE_PLUGIN_DIRS": "/my/plugin"]], folder: folder)
        #expect(ClaudeBridge.pluginDirs(in: ClaudeBridge.removing(from: shared, folder: folder)) == ["/my/plugin"])
    }

    @Test func theModIsAValidClaudeCodePlugin() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try ClaudeBridge.writeFiles(to: temp)
        #expect(FileManager.default.fileExists(atPath: temp.appending(path: ".claude-plugin/plugin.json").path))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: temp.appending(path: ".claude-plugin/plugin.json")))
        #expect((manifest as? [String: Any])?["name"] as? String == "notchman-bridge")
        // With Claude Code on this Mac, have it check the mod too.
        let candidates = [NSHomeDirectory() + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let claude = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let output = try await Shell.run(claude, ["plugin", "validate", temp.path], timeout: 60)
        #expect(output.contains("prompt.submit") && output.contains("tool.call") && output.contains("turn.complete"),
                "validate lists the hooks: \(output)")
    }

    @Test func signalsSayWhatTheSessionIsDoing() {
        let start = Date()
        var activity = SessionSignal(event: "prompt", session: "s1", text: "fix the build").apply(to: nil, now: start)
        #expect(activity.lastAction == "Thinking" && activity.isTurnRunning && activity.lastPrompt == "fix the build")
        activity = SessionSignal(event: "tool", session: "s1", tool: "Edit", file: "/repo/Sources/ShelfView.swift")
            .apply(to: activity, now: start)
        #expect(activity.lastAction == "Editing ShelfView.swift" && activity.changedFiles == ["/repo/Sources/ShelfView.swift"])
        activity = SessionSignal(event: "tool", session: "s1", tool: "Bash", command: "swift test", description: "Run the tests")
            .apply(to: activity, now: start)
        #expect(activity.lastAction == "Run the tests")
        activity = SessionSignal(event: "tool", session: "s1", tool: "Read", file: "/repo/README.md").apply(to: activity, now: start)
        #expect(activity.files == ["/repo/README.md", "/repo/Sources/ShelfView.swift"])
        #expect(activity.changedFiles == ["/repo/Sources/ShelfView.swift"], "reading isn't changing")
        activity = SessionSignal(event: "turn.complete", session: "s1", aborted: false).apply(to: activity, now: start)
        #expect(activity.lastAction == "Finished" && !activity.isTurnRunning)
        #expect(activity.isFresh(now: start.addingTimeInterval(60)) && !activity.isFresh(now: start.addingTimeInterval(3600)))
    }

    @Test func signalsDecodeFromWhatTheModSends() throws {
        let body = #"{"event":"tool","tool":"Write","file":"/a/b.txt","command":null,"description":null,"session":"abc","cwd":"/a"}"#
        let signal = try JSONDecoder().decode(SessionSignal.self, from: Data(body.utf8))
        #expect(signal.session == "abc" && signal.tool == "Write" && signal.file == "/a/b.txt")
    }

    @Test func theAppTracksFilesClaudeChanged() {
        let app = ChatApp()
        app.receive(SessionSignal(event: "tool", session: "s1", tool: "Write", file: "/tmp/new-notes.md"))
        #expect(app.sessionActivity["s1"]?.lastAction == "Writing new-notes.md")
        #expect(NotchBoard.shared.agentFiles.contains(URL(fileURLWithPath: "/tmp/new-notes.md")))
    }
}
