import AppKit
import SwiftUI
import Testing
@testable import ChatApp

@MainActor @Suite struct AgentsSummaryTests {
    @Test func needsYouBeatsWorkingBeatsReady() {
        #expect(ChatApp.summary(needsYou: 2, workingAgents: 3, writingChats: [.chatgpt], readyAgents: 1, readyChats: [])
                == .init(kind: .needsYou, label: "2 need you"))
        #expect(ChatApp.summary(needsYou: 1, workingAgents: 0, writingChats: [], readyAgents: 0, readyChats: [])?.label == "1 needs you")
        #expect(ChatApp.summary(needsYou: 0, workingAgents: 2, writingChats: [.claude], readyAgents: 4, readyChats: [])
                == .init(kind: .working, label: "3 working"))
        #expect(ChatApp.summary(needsYou: 0, workingAgents: 0, writingChats: [], readyAgents: 1, readyChats: [.muse])
                == .init(kind: .ready, label: "2 ready"))
        #expect(ChatApp.summary(needsYou: 0, workingAgents: 0, writingChats: [], readyAgents: 0, readyChats: []) == nil)
    }

    @Test func aSingleChatShowsItsName() {
        #expect(ChatApp.summary(needsYou: 0, workingAgents: 0, writingChats: [.chatgpt], readyAgents: 0, readyChats: [])?.label == "GPT")
        #expect(ChatApp.summary(needsYou: 0, workingAgents: 0, writingChats: [], readyAgents: 0, readyChats: [.claude])?.label == "Claude")
        #expect(ChatApp.summary(needsYou: 0, workingAgents: 1, writingChats: [], readyAgents: 0, readyChats: [])?.label == "1 working")
    }

    @MainActor @Test func monitorAnnouncesChangesNotTheFirstSnapshot() {
        let monitor = ClaudeAgentsMonitor(defaults: UserDefaults(suiteName: "notchman.tests.agents")!)
        let working = ClaudeAgent(id: "a", shortID: "a", name: "Fix bug", cwd: "/tmp/p", kind: .background,
                                  state: "working", status: "busy", startedAt: .now)
        let blocked = ClaudeAgent(id: "a", shortID: "a", name: "Fix bug", cwd: "/tmp/p", kind: .background,
                                  state: "blocked", status: "idle", startedAt: .now)
        #expect(monitor.apply([blocked], now: .now).isEmpty)
        #expect(monitor.apply([working], now: .now).isEmpty)
        #expect(monitor.apply([blocked], now: .now) == [.needsYou(blocked)])
        #expect(monitor.recentFolders == ["/tmp/p"])
    }

    /// Renders the Overview with realistic agents into build/dev for eyeballing.
    @MainActor @Test func rendersOverview() throws {
        let monitor = ClaudeAgentsMonitor(defaults: UserDefaults(suiteName: "notchman.tests.agents")!)
        let now = Date()
        monitor.apply([
            ClaudeAgent(id: "1", shortID: "2c1417b0", name: "Dashboard repository integration plan", cwd: "/Users/me/GitHub/JobManager",
                        kind: .background, state: "blocked", status: "idle", startedAt: now.addingTimeInterval(-7200)),
            ClaudeAgent(id: "2", shortID: "08991a1b", name: "notchman-engine-setup", cwd: "/Users/me/GitHub/NotchMan",
                        kind: .background, state: "working", status: "busy", startedAt: now.addingTimeInterval(-600)),
            ClaudeAgent(id: "3", shortID: nil, name: "superleads-jj-9b", cwd: "/Users/me/GitHub/superleads",
                        kind: .interactive, state: nil, status: "busy", startedAt: now.addingTimeInterval(-60)),
            ClaudeAgent(id: "4", shortID: "db8a961e", name: "chat nodes debug messaging", cwd: "/Users/me/GitHub/coachbot",
                        kind: .background, state: "done", status: "idle", startedAt: now.addingTimeInterval(-86400)),
            ClaudeAgent(id: "5", shortID: nil, name: "notchman-77", cwd: "/Users/me/GitHub/NotchMan",
                        kind: .interactive, state: nil, status: "idle", startedAt: now.addingTimeInterval(-3 * 86400)),
        ], now: now)
        let app = ChatApp()
        app.useAgentMonitor(monitor)
        app.useUnseenForTesting(["1"])
        // Scroll views don't render offscreen, so draw the strip and the sections directly.
        let view = VStack(alignment: .leading, spacing: 8) {
            AgentsOverview(app: app).frame(height: 40)
            AgentSections(app: app)
            Spacer()
        }
            .padding(14)
            .frame(width: 720, height: 420)
            .background(.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let tiff = try #require(renderer.nsImage?.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../build/dev").standardizedFileURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appending(path: "agents-overview.png"))
    }
}
