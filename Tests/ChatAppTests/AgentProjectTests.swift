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
        ], folders: [])
        #expect(projects.map(\.name) == ["JobManager", "NotchMan", "coachbot"])  // needs you, working, done
        let notchMan = projects[1]
        #expect(notchMan.agents.map(\.id) == ["2", "1"])
        #expect(notchMan.phase == .working)
        #expect(notchMan.startsExpanded)
        #expect(notchMan.summary == "1 working · 1 done")
        #expect(!notchMan.showsAsRow)
        #expect(projects[0].showsAsRow, "a project's folder with one session is just its row")
        #expect(!projects[2].startsExpanded)
    }

    @Test func movedSessionsLeaveTheirProjectsFolder() {
        let notchMan = AgentFolder.forProject("/Users/me/GitHub/NotchMan")
        let both = AgentFolder(name: "NotchMan + JobManager", sessions: ["3"])
        let later = AgentFolder(name: "Later")
        let unused = AgentFolder.forProject("/Users/me/GitHub/old")
        let projects = AgentProject.group([
            agent("1", "/Users/me/GitHub/NotchMan", state: "blocked", ago: 50),
            agent("2", "/Users/me/GitHub/NotchMan", state: "done", ago: 60),
            agent("3", "/Users/me/GitHub/JobManager", state: "working", status: "busy", ago: 70),
            agent("4", "/Users/me", state: "done", ago: 80),
        ], folders: [notchMan, both, later, unused])
        // An empty folder you made waits at the top; a project's folder with nothing in it doesn't show.
        #expect(projects.map(\.name) == ["Later", "NotchMan", "NotchMan + JobManager", "me"])
        #expect(projects[1].agents.map(\.id) == ["1", "2"])
        #expect(projects[2].agents.map(\.id) == ["3"])
        #expect(!projects[2].showsAsRow, "a folder you made always shows as a folder")
        #expect(projects[3].showsAsRow)
        #expect(AgentProject.missingProjects([agent("4", "/Users/me", state: nil, ago: 1)], folders: [notchMan]) == ["/Users/me"])
    }

    @Test func movingSessionsBetweenFolders() throws {
        let monitor = ClaudeAgentsMonitor(defaults: UserDefaults(suiteName: "notchman.tests.agents.folders")!)
        let stray = agent("3", "/Users/me", state: "done", ago: 3)
        monitor.apply([agent("1", "/Users/me/GitHub/NotchMan", state: "done", ago: 1),
                       agent("2", "/Users/me/GitHub/NotchMan/.claude/worktrees/x", state: "done", ago: 2), stray], now: now)
        let app = ChatApp()
        app.useAgentMonitor(monitor)
        app.agentFolders = [AgentFolder(name: "Both", sessions: ["old"])]
        app.syncFolders()
        #expect(app.agentFolders.map(\.name) == ["Both", "NotchMan", "me"], "a folder per project")
        #expect(app.agentFolders[0].sessions.isEmpty, "sessions that no longer exist are forgotten")
        let notchMan = try #require(app.agentFolders.first { $0.name == "NotchMan" })

        app.move(["3"], to: notchMan.id)
        #expect(app.listedFolder(of: stray)?.id == notchMan.id)
        app.move(["1"], to: notchMan.id)
        #expect(app.folder(of: "1") == nil, "its own project's folder takes it anyway")
        #expect(AgentProject.group(monitor.agents, folders: app.agentFolders).first { $0.name == "NotchMan" }?
            .agents.map(\.id).sorted() == ["1", "2", "3"])
        #expect(app.shownFolders.map(\.name) == ["Both", "NotchMan"], "the menu lists the folders on screen")

        app.move(["3"], to: app.agentFolders[0].id)
        #expect(app.folder(of: "3")?.name == "Both")
        app.move(["3"], to: nil)
        #expect(app.listedFolder(of: stray)?.name == "me")

        // Renaming keeps it collecting its project; deleting it makes a fresh one for the project's sessions.
        app.agentFolders[1].name = "Notch"
        #expect(AgentProject.group(monitor.agents, folders: app.agentFolders).first { $0.name == "Notch" }?.agents.count == 2)
        app.deleteFolder(app.agentFolders[1].id)
        let fresh = try #require(app.agentFolders.first { $0.projects == ["/Users/me/GitHub/NotchMan"] })
        #expect(fresh.name == "NotchMan" && fresh.id != notchMan.id)
    }

    @Test func earlierFoldersAndPlacementsCarryOver() throws {
        let saved = #"[{"id":"6F0C5C11-2C1C-4C55-9A2B-3B1C5D0E9A11","name":"Job hunt","sessions":["9"]}]"#
        let folders = try JSONDecoder().decode([AgentFolder].self, from: Data(saved.utf8))
        #expect(folders[0].projects.isEmpty && folders[0].sessions == ["9"])
        let merged = ChatApp.foldersWithPlacements(folders, ["3": "/Users/me/GitHub/NotchMan", "9": "/Users/me/x"])
        #expect(merged.count == 2)
        #expect(merged[1].name == "NotchMan" && merged[1].sessions == ["3"] && merged[1].projects == ["/Users/me/GitHub/NotchMan"])
        #expect(merged[0].sessions == ["9"], "a session already in a folder stays there")
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
        let folder = AgentFolder(name: "NotchMan + JobManager", sessions: ["4", "1"])
        app.agentFolders = [folder, AgentFolder(name: "Someday")]
        app.projectExpansion["folder:\(folder.id)"] = true
        let view = AgentProjectTree(app: app)
            .padding(14)
            .frame(width: 720, height: 460, alignment: .top)
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
