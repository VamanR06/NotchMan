import AppKit
import SwiftUI
import Testing
@testable import ChatApp

@MainActor @Suite struct AgentProjectTests {
    private let now = Date()

    private func agent(_ id: String, _ cwd: String, state: String?, status: String = "idle", ago: TimeInterval,
                       kind: ClaudeAgent.Kind = .background) -> ClaudeAgent {
        ClaudeAgent(id: id, shortID: kind == .background ? id : nil, name: "Session \(id)", cwd: cwd, kind: kind,
                    state: state, status: status, startedAt: now.addingTimeInterval(-ago))
    }

    @Test func sessionsInOneProjectAndItsWorktreesGoTogether() {
        let projects = AgentProject.group([
            agent("1", "/Users/me/GitHub/NotchMan", state: "done", ago: 50),
            agent("2", "/Users/me/GitHub/NotchMan/.claude/worktrees/tree-view", state: "working", status: "busy", ago: 100),
            agent("3", "/Users/me/GitHub/JobManager", state: "blocked", ago: 500),
            agent("4", "/Users/me/GitHub/coachbot", state: "done", ago: 10),
        ])
        #expect(projects.map(\.name) == ["JobManager", "NotchMan", "coachbot"])  // needs you, working, done
        let notchMan = projects[1]
        #expect(notchMan.agents.map(\.id) == ["2", "1"])
        #expect(notchMan.phase == .working)
        #expect(notchMan.startsExpanded)
        #expect(notchMan.summary == "1 working · 1 done")
        #expect(!projects[2].startsExpanded)
    }

    /// Renders the project tree into build/dev for eyeballing.
    @Test func rendersProjectTree() throws {
        let monitor = ClaudeAgentsMonitor(defaults: UserDefaults(suiteName: "notchman.tests.agents.tree")!)
        monitor.apply([
            agent("1", "/Users/me/GitHub/NotchMan", state: "blocked", ago: 7200),
            agent("2", "/Users/me/GitHub/NotchMan/.claude/worktrees/notch-ui-tweaks", state: "working", status: "busy", ago: 600),
            agent("3", "/Users/me/GitHub/NotchMan", state: nil, ago: 3 * 86400, kind: .interactive),
            agent("4", "/Users/me/GitHub/JobManager", state: "working", status: "busy", ago: 60),
            agent("5", "/Users/me/GitHub/coachbot", state: "done", ago: 86400),
            agent("6", "/Users/me/GitHub/coachbot/.claude/worktrees/fix-chat", state: "done", ago: 90000),
        ], now: now)
        let app = ChatApp()
        app.useAgentMonitor(monitor)
        app.useUnseenForTesting(["1"])
        let view = AgentProjectTree(app: app)
            .padding(14)
            .frame(width: 720, height: 330, alignment: .top)
            .background(.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let tiff = try #require(renderer.nsImage?.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../build/dev").standardizedFileURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appending(path: "agents-project-tree.png"))
    }
}
