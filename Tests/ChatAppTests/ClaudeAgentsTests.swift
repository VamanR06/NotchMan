import Foundation
import Testing
@testable import ChatApp

/// Shaped like `claude agents --json` (fields observed on a real machine; some entries omit fields).
private let fixture = """
[
  {"id": "2c1417b0", "sessionId": "2c1417b0-b6fe-4857-b677-eb70dd588331", "name": "Dashboard plan",
   "cwd": "/Users/me/GitHub/JobManager", "kind": "background", "state": "blocked", "startedAt": 1792400000000},
  {"sessionId": "486d7c97-6ffb-4493-b60d-699a7558c474", "name": "superleads-jj-9b", "cwd": "/Users/me/GitHub/superleads",
   "kind": "interactive", "status": "idle", "pid": 123, "startedAt": 1792300000000},
  {"id": "08991a1b", "sessionId": "08991a1b-c176-4819-8d02-4903b8c7d361", "name": "notchman-engine-setup",
   "cwd": "/Users/me/GitHub/NotchMan", "kind": "background", "state": "working", "status": "busy", "startedAt": 1792450000000},
  {"id": "db8a961e", "sessionId": "db8a961e-1a6b-4589-a252-7eff653d049d", "name": "",
   "cwd": "/Users/me/GitHub/coachbot", "kind": "background", "state": "done", "status": "idle"},
  {"name": "no session id, skipped"}
]
"""

private func agents() throws -> [ClaudeAgent] {
    try ClaudeAgent.decodeList(Data(fixture.utf8))
}

@Suite struct ClaudeAgentDecodingTests {
    @Test func decodesRealShape() throws {
        let list = try agents()
        #expect(list.count == 4)
        #expect(list[0].shortID == "2c1417b0" && list[0].kind == .background && list[0].phase == .needsYou)
        #expect(list[1].shortID == nil && list[1].kind == .interactive && list[1].phase == .idle)
        #expect(list[2].phase == .working)
        // Empty name falls back to the project folder.
        #expect(list[3].name == "coachbot" && list[3].phase == .done && list[3].startedAt == nil)
        #expect(list[0].startedAt == Date(timeIntervalSince1970: 1_792_400_000))
        #expect(list[0].project == "JobManager")
    }

    @Test func sortsNeedsYouFirstThenNewest() throws {
        let sorted = ClaudeAgent.sorted(try agents())
        #expect(sorted.map(\.phase) == [.needsYou, .working, .done, .idle])
    }
}

@Suite struct AgentTransitionTests {
    private func agent(_ id: String, kind: ClaudeAgent.Kind = .background, state: String? = nil, status: String? = nil) -> ClaudeAgent {
        ClaudeAgent(id: id, shortID: kind == .background ? id : nil, name: id, cwd: "/tmp", kind: kind,
                    state: state, status: status, startedAt: nil)
    }

    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func blockedAndDoneNotify() {
        let old = ["a": agent("a", state: "working"), "b": agent("b", state: "working")]
        let events = AgentTransitions.events(from: old, to: [agent("a", state: "blocked"), agent("b", state: "done")],
                                             workingSince: [:], now: now)
        #expect(events.map(\.agent.id) == ["a", "b"])
        #expect(events.first == .needsYou(agent("a", state: "blocked")))
    }

    @Test func newAgentsAndUnchangedOnesAreQuiet() {
        let old = ["a": agent("a", state: "blocked")]
        let events = AgentTransitions.events(from: old, to: [agent("a", state: "blocked"), agent("new", state: "blocked")],
                                             workingSince: [:], now: now)
        #expect(events.isEmpty)
    }

    @Test func interactiveFinishOnlyAfterRealWork() {
        let old = ["i": agent("i", kind: .interactive, status: "busy")]
        let idle = [agent("i", kind: .interactive, status: "idle")]
        #expect(AgentTransitions.events(from: old, to: idle, workingSince: ["i": now.addingTimeInterval(-3)], now: now).isEmpty)
        #expect(AgentTransitions.events(from: old, to: idle, workingSince: ["i": now.addingTimeInterval(-30)], now: now).count == 1)
    }
}

@Suite struct AgentScriptTests {
    @Test func quotesForTheShell() {
        #expect(Shell.quote("plain") == "'plain'")
        #expect(Shell.quote("it's $HOME; rm -rf /") == "'it'\\''s $HOME; rm -rf /'")
    }

    @Test func commandFileRunsInTheProjectFolder() {
        let script = AgentScripts.commandFile(cwd: "/Users/me/My Project", command: "'/usr/local/bin/claude' attach 'abc'")
        #expect(script == "#!/bin/zsh -l\ncd '/Users/me/My Project' || exit 1\nexec '/usr/local/bin/claude' attach 'abc'\n")
    }

    @Test func shellRunsAndReportsFailures() async throws {
        #expect(try await Shell.run("/bin/echo", ["hi"]) == "hi\n")
        await #expect(throws: Shell.ShellError.self) { try await Shell.run("/bin/sh", ["-c", "echo nope >&2; exit 3"]) }
        #expect(try await Shell.run("/bin/pwd", [], in: "/tmp").hasSuffix("tmp\n"))
    }
}

@Suite struct AgentSearchTests {
    private let agent = ClaudeAgent(id: "1", shortID: "a", name: "scraping-pipeline-docs", cwd: "/Users/me/GitHub/tajmahome-jj",
                                    kind: .background, state: "done", status: nil, startedAt: nil)

    @Test func matchesNameOrProjectIgnoringCase() {
        #expect(agent.matches(""))
        #expect(agent.matches("  "))
        #expect(agent.matches("PIPELINE"))
        #expect(agent.matches("tajmahome"))
        #expect(!agent.matches("coachbot"))
    }

    @Test func finishedSessionsWithoutAProcessAreDone() throws {
        // `--all` lists ended sessions with no `status`.
        let list = try ClaudeAgent.decodeList(Data(#"[{"id":"5774c1c3","sessionId":"5774c1c3-3d91","name":"docs","cwd":"/x","kind":"background","state":"done"}]"#.utf8))
        #expect(list.first?.phase == .done && list.first?.shortID == "5774c1c3")
    }
}

/// Runs stop/delete against a stand-in `claude` that records its arguments.
@MainActor @Suite(.serialized) struct SessionCommandTests {
    private func stubClaude() throws -> (path: String, log: String) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "notchman-claude-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appending(path: "args.log").path
        let script = dir.appending(path: "claude").path
        // `agents` (the refresh after each command) prints an empty list; everything else is logged.
        try """
        #!/bin/sh
        if [ "$1" = "agents" ]; then echo '[]'; exit 0; fi
        echo "$@" >> '\(log)'
        if [ "$2" = "dirty" ]; then echo "worktree has unpushed commits: pass --discard-unpushed abc@wt1" >&2; exit 1; fi
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        return (script, log)
    }

    private func agent(_ short: String?) -> ClaudeAgent {
        ClaudeAgent(id: "full-\(short ?? "x")", shortID: short, name: "S", cwd: "/tmp",
                    kind: short == nil ? .interactive : .background, state: "done", status: nil, startedAt: nil)
    }

    @Test func stopAndDeleteRunTheRightCommandWithoutForceFlags() async throws {
        let (path, log) = try stubClaude()
        let defaults = UserDefaults(suiteName: "notchman.tests.sessioncmd")!
        let monitor = ClaudeAgentsMonitor(defaults: defaults)
        monitor.claudePathOverride = path
        try await monitor.stop(agent("abc123"))
        try await monitor.delete(agent("abc123"))
        let lines = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n")
        #expect(lines == ["stop abc123", "rm abc123"])
        defaults.removeObject(forKey: "claudePath")
    }

    @Test func refusalsAreReportedNotForced() async throws {
        let (path, log) = try stubClaude()
        let defaults = UserDefaults(suiteName: "notchman.tests.sessioncmd")!
        let monitor = ClaudeAgentsMonitor(defaults: defaults)
        monitor.claudePathOverride = path
        await #expect(throws: Shell.ShellError.self) { try await monitor.delete(agent("dirty")) }
        #expect(try String(contentsOfFile: log, encoding: .utf8) == "rm dirty\n", "no retry with --discard-unpushed")
        await #expect(throws: Shell.ShellError.self) { try await monitor.delete(agent(nil)) }  // interactive
        defaults.removeObject(forKey: "claudePath")
    }
}
