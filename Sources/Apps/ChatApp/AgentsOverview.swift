import AppKit
import NotchKit
import SwiftUI

/// The Agents app's Overview: the three web chats at a glance, then Claude Code agents by phase.
struct AgentsOverview: View {
    @Bindable var app: ChatApp

    var body: some View {
        if app.showingShells {
            ShellScreen(app: app, shells: app.shells)
        } else if let terminal = app.shownTerminal {
            AgentTerminalScreen(app: app, terminal: terminal)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ChatStrip(app: app)
                ForEach(app.approvals) { request in
                    ApprovalCard(app: app, request: request)
                }
                UsageCard(app: app)
                if app.composingAgent {
                    NewAgentForm(app: app)
                }
                HStack(spacing: 6) {
                    SessionSearch(app: app)
                    if app.groupsAgentsByProject { NewFolderButton(app: app) }
                    GroupingToggle(app: app)
                }
                AgentList(app: app)
            }
            .onAppear { app.markOverviewSeen() }
        }
    }
}

/// A tool call waiting for permission: what it wants, why it might be risky, and the answer buttons.
private struct ApprovalCard: View {
    let app: ChatApp
    let request: ApprovalRequest

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(request.risk == nil ? .orange : .red)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(request.toolName).font(.system(size: 12, weight: .semibold))
                    Text(request.project).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    if let risk = request.risk {
                        Text("⚠ \(risk)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.red)
                    }
                }
                Text(request.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Button("Deny") { app.resolveApproval(request.id, .deny) }
                    Button("Allow") { app.resolveApproval(request.id, .allow) }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
                Button("Ask in terminal") { app.resolveApproval(request.id, .terminal) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill((request.risk == nil ? Color.orange : .red).opacity(0.12)))
    }
}

/// ChatGPT / Claude / Muse status pills (click to open that chat), then Terminal.
private struct ChatStrip: View {
    let app: ChatApp

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ChatService.allCases) { service in
                Button { app.show(service) } label: {
                    HStack(spacing: 6) {
                        statusMark(service)
                        Text(service.name).font(.system(size: 12, weight: .semibold))
                        Text(statusText(service)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            terminalPill
        }
    }

    /// Opens your own terminals in the notch (a new one in the last folder you used, if none are open).
    private var terminalPill: some View {
        let tabs = app.shells.tabs
        let busy = tabs.contains { $0.session.isBusy }
        return Button { app.openShell() } label: {
            HStack(spacing: 6) {
                if busy {
                    NotchSpinner(size: 11, lineWidth: 1.6)
                } else {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                }
                Text("Terminal").font(.system(size: 12, weight: .semibold))
                Text(busy ? "running…" : tabs.isEmpty ? "⌘T" : "\(tabs.count) open")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tabs.isEmpty ? "Open a terminal in \(app.shellFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
                           : "Back to your terminals")
        .task(id: tabs.count) {
            // So "running…" follows a long command (a clone, a build) you left going.
            while !Task.isCancelled && !tabs.isEmpty {
                tabs.forEach { $0.session.refresh() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .contextMenu {
            Button("New Terminal in Home") { app.openShell(in: NSHomeDirectory()) }
            ForEach(app.agentMonitor.recentFolders, id: \.self) { path in
                Button("New Terminal in \(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))") { app.openShell(in: path) }
            }
            Divider()
            Button("New Terminal in Folder…") {
                if let path = ChatApp.chooseFolder(startingIn: app.shellFolder) { app.openShell(in: path) }
            }
        }
    }

    @ViewBuilder
    private func statusMark(_ service: ChatService) -> some View {
        if app.isBusy(service) {
            NotchSpinner(size: 11, lineWidth: 1.6)
        } else if app.unread.contains(service) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
        } else {
            Circle().fill(.white.opacity(0.25)).frame(width: 7, height: 7).frame(width: 11)
        }
    }

    private func statusText(_ service: ChatService) -> String {
        if app.isBusy(service) { return "writing…" }
        if app.unread.contains(service) { return "reply ready" }
        return ""
    }
}

private struct AgentList: View {
    let app: ChatApp

    private var monitor: ClaudeAgentsMonitor { app.agentMonitor }

    var body: some View {
        if !monitor.hasLoaded {
            centered(monitor.error ?? "Looking for Claude Code sessions…", isError: monitor.error != nil)
        } else if monitor.agents.isEmpty {
            centered("No Claude Code sessions running. Start one with New Agent.", isError: false)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                if app.groupsAgentsByProject {
                    AgentProjectTree(app: app, lazy: true)
                } else {
                    AgentSections(app: app, lazy: true)
                }
            }
        }
    }

    private func centered(_ text: String, isError: Bool) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(isError ? .orange : .white.opacity(0.5))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Agents grouped by phase (Needs you, Working, Done, Idle).
struct AgentSections: View {
    let app: ChatApp
    /// Lazy inside the scroll view; plain when rendered on its own (e.g. in tests).
    var lazy = false

    var body: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) { sections }
        } else {
            VStack(alignment: .leading, spacing: 2) { sections }
        }
    }

    @ViewBuilder
    private var sections: some View {
        let searching = !app.agentQuery.trimmingCharacters(in: .whitespaces).isEmpty
        ForEach([ClaudeAgent.Phase.needsYou, .working, .done, .idle], id: \.self) { phase in
            let agents = app.agentMonitor.agents.filter { $0.phase == phase && $0.matches(app.agentQuery) }
            // Done can hold every finished session; show the latest few unless expanded or searching.
            let folded = phase == .done && !searching && !app.showAllCompleted && agents.count > Self.recentDone
            if !agents.isEmpty {
                Section {
                    ForEach(folded ? Array(agents.prefix(Self.recentDone)) : agents) { AgentRow(app: app, agent: $0) }
                    if phase == .done && !searching && agents.count > Self.recentDone {
                        OlderToggle(app: app, hidden: agents.count - Self.recentDone)
                    }
                } header: {
                    Text("\(title(phase)) · \(agents.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(phase == .needsYou ? .orange : .white.opacity(0.5))
                        .textCase(.uppercase)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                        .background(.black)
                }
            }
        }
    }

    static let recentDone = 5

    private func title(_ phase: ClaudeAgent.Phase) -> String {
        switch phase {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .done: "Done"
        case .idle: "Idle"
        }
    }
}

/// Agents in folders: each project's sessions (worktrees count as their repo) in its own folder unless you moved
/// them into another one, under a row you can fold; a project's folder with one session is just that session's row.
/// Most urgent first, like the status view.
struct AgentProjectTree: View {
    let app: ChatApp
    /// Lazy inside the scroll view; plain when rendered on its own (e.g. in tests).
    var lazy = false

    var body: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: 2) { rows }
        } else {
            VStack(alignment: .leading, spacing: 2) { rows }
        }
    }

    @ViewBuilder
    private var rows: some View {
        let searching = !app.agentQuery.trimmingCharacters(in: .whitespaces).isEmpty
        let projects = AgentProject.group(app.agentMonitor.agents.filter { $0.matches(app.agentQuery) },
                                          folders: app.agentFolders)
            .filter { !(searching && $0.agents.isEmpty) }
        // Finished folders pile up; show the latest few unless expanded or searching.
        let done = projects.filter { $0.phase == .done && !$0.agents.isEmpty }
        let hidden = searching || app.showAllCompleted ? [] : Set(done.dropFirst(AgentSections.recentDone).map(\.id))
        ForEach(projects.filter { !hidden.contains($0.id) }) { project in
            if project.showsAsRow, let agent = project.agents.first {
                AgentRow(app: app, agent: agent)
            } else {
                let expanded = searching || (app.projectExpansion[project.id] ?? project.startsExpanded)
                ProjectRow(app: app, project: project, expanded: expanded)
                if expanded {
                    Group {
                        ForEach(project.agents) { agent in
                            AgentRow(app: app, agent: agent, treeFolder: project.path)
                        }
                        if project.agents.isEmpty {
                            Text("Drag sessions here, or right-click one → Move to Folder.")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                        }
                    }
                    .padding(.leading, 20)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.12)).frame(width: 1).padding(.leading, 12)
                    }
                }
            }
        }
        if !searching && done.count > AgentSections.recentDone {
            OlderToggle(app: app, hidden: done.count - AgentSections.recentDone)
        }
    }
}

/// A folder: click to show or hide its sessions; drop a session on it to move it there.
private struct ProjectRow: View {
    @Bindable var app: ChatApp
    let project: AgentProject
    let expanded: Bool
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 9) {
            PhaseMark(phase: project.phase).frame(width: 14).opacity(project.agents.isEmpty ? 0 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                    Text(project.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(project.agents.count)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.15)))
                        .foregroundStyle(.white.opacity(0.75))
                    if project.agents.contains(where: { app.unseenAgents.contains($0.id) }) {
                        Circle().fill(project.phase == .needsYou ? .orange : .green).frame(width: 6, height: 6)
                    }
                }
                Text(project.agents.isEmpty ? "Empty" : project.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .foregroundStyle(.white.opacity(hovering ? 0.7 : 0.4))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hovering ? 0.08 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.blue, lineWidth: targeted ? 1.5 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { app.projectExpansion[project.id] = !expanded }
        }
        .dropDestination(for: String.self) { sessions, _ in
            withAnimation(.easeOut(duration: 0.15)) { app.move(sessions, to: project.folder.id) }
            return true
        } isTargeted: { targeted = $0 }
        .help(project.path.map { "Collects sessions from " + $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
              ?? "Holds the sessions you move here")
        .contextMenu {
            Button("Rename…") { app.renameFolder(project.folder.id) }
            Button("Delete Folder") { withAnimation { app.deleteFolder(project.folder.id) } }
                .help("Its sessions go back to their projects' folders")
            if let path = project.path {
                Divider()
                Button("New Agent Here…") { app.composeAgent(in: path) }
                Button("Open Project in \(app.editor.name)") { app.editor.open(path) }
                Button("Open Terminal Here") { app.openShell(in: path) }
                Button("Reveal Project in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            if !project.agents.isEmpty {
                Divider()
                MoveToFolderMenu(app: app, sessions: project.agents.map(\.id), title: "Move All to Folder")
            }
        }
    }
}

/// "Move to Folder" ▸ every folder on the Overview and New Folder…, plus sending a session back to its project's
/// folder.
private struct MoveToFolderMenu: View {
    let app: ChatApp
    let sessions: [String]
    var title = "Move to Folder"

    var body: some View {
        let one = sessions.count == 1 ? app.agentMonitor.agents.first { $0.id == sessions[0] } : nil
        let listed = one.flatMap { app.listedFolder(of: $0) }
        Menu(title) {
            ForEach(app.shownFolders) { folder in
                Button(folder.name) { withAnimation { app.move(sessions, to: folder.id) } }
                    .disabled(folder.id == listed?.id)
            }
            Divider()
            Button("New Folder…") { withAnimation { _ = app.newFolder(with: sessions) } }
        }
        if let one, app.folder(of: one.id) != nil {
            let own = URL(fileURLWithPath: ClaudeAgentsMonitor.projectFolder(one.cwd)).lastPathComponent
            Button("Move Back to \(own)") { withAnimation { app.move(sessions, to: nil) } }
        }
    }
}

/// Makes a folder of your own on the Overview.
private struct NewFolderButton: View {
    let app: ChatApp

    var body: some View {
        Button { withAnimation { _ = app.newFolder() } } label: {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.7))
        .help("New folder for sessions (drag sessions onto it)")
    }
}

/// Switches the Overview between sessions by project and by status.
private struct GroupingToggle: View {
    @Bindable var app: ChatApp

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { app.groupsAgentsByProject.toggle() }
        } label: {
            Image(systemName: app.groupsAgentsByProject ? "folder" : "list.bullet")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.7))
        .help(app.groupsAgentsByProject ? "By project — show by status instead" : "By status — show by project instead")
    }
}

/// Needs you / working / done / idle, as a small mark.
private struct PhaseMark: View {
    let phase: ClaudeAgent.Phase

    var body: some View {
        switch phase {
        case .needsYou:
            Image(systemName: "exclamationmark.bubble.fill").font(.system(size: 12)).foregroundStyle(.orange)
        case .working:
            NotchSpinner(size: 11, lineWidth: 1.6)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
        case .idle:
            Image(systemName: "moon.zzz").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
        }
    }
}

/// Plan limit bars ("Current session", "Current week") from `claude -p "/usage"` — the numbers that actually
/// decide when you'll be rate-limited, not just token counts.
private struct LimitsRow: View {
    let app: ChatApp

    var body: some View {
        let agent = app.agentMonitor
        HStack(alignment: .top, spacing: 16) {
            if let limits = agent?.limits, !limits.windows.isEmpty {
                ForEach(limits.windows) { window in
                    LimitBar(window: window)
                }
            } else if let error = agent?.limitsError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                HStack(spacing: 5) {
                    NotchSpinner(size: 9, color: .white.opacity(0.5), lineWidth: 1.4)
                    Text("Checking plan limits…").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct LimitBar: View {
    let window: ClaudeLimitWindow

    private var tint: Color {
        window.isAtLimit ? .red : (window.isNearLimit ? .orange : .white)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(window.label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                Text("\(window.percent)%").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(tint).frame(width: geo.size.width * CGFloat(min(window.percent, 100)) / 100)
                }
            }
            .frame(width: 92, height: 4)
            Text("resets \(window.resetsText)")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
        }
        .help(window.label + ": " + "\(window.percent)% used, resets \(window.resetsText)")
    }
}

/// Claude Code token usage: last 5 hours, today and 7 days; expands into a 7-day breakdown.
struct UsageCard: View {
    @Bindable var app: ChatApp
    @State private var breakdown: Breakdown

    init(app: ChatApp, initialBreakdown: Breakdown = .model) {
        self.app = app
        _breakdown = State(initialValue: initialBreakdown)
    }

    enum Breakdown: String, CaseIterable, Identifiable {
        case model = "Models", project = "Projects", session = "Sessions"
        var id: Self { self }
    }

    private var monitor: ClaudeUsageMonitor { app.usageMonitor }

    var body: some View {
        let summary = monitor.summary
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { app.showUsageBreakdown.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chart.bar.fill").font(.system(size: 11)).foregroundStyle(.orange)
                    Text("Claude Code usage").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    if monitor.hasLoaded {
                        stat("5h", summary.lastFiveHours.work)
                        stat("Today", summary.today.work)
                        stat("7 days", summary.week.work)
                    } else {
                        NotchSpinner(size: 10, lineWidth: 1.5)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(app.showUsageBreakdown ? 90 : 0))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Tokens used by Claude Code on this Mac (input + output + cache writes)")

            LimitsRow(app: app)

            if app.showUsageBreakdown {
                breakdownView(summary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
        .task {
            // Fresh on appear, then every minute while on screen (limits themselves only re-fetch every 2m).
            while !Task.isCancelled {
                await app.refreshUsage()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func stat(_ label: String, _ tokens: Int) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.white.opacity(0.5))
            Text(UsageSummary.format(tokens)).foregroundStyle(.white).monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium))
    }

    @ViewBuilder
    private func breakdownView(_ summary: UsageSummary) -> some View {
        let slices: [UsageSlice] = switch breakdown {
        case .model: summary.byModel
        case .project: summary.byProject
        case .session: summary.bySession
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Breakdown.allCases) { option in
                    Button { breakdown = option } label: {
                        Text(option.rawValue)
                            .font(.system(size: 10, weight: breakdown == option ? .semibold : .regular))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(breakdown == option ? 0.2 : 0)))
                            .foregroundStyle(.white.opacity(breakdown == option ? 1 : 0.6))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("last 7 days").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
            if slices.isEmpty {
                Text("No Claude Code usage in the last 7 days.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            let top = max(slices.first?.work ?? 1, 1)
            ForEach(slices) { slice in
                HStack(spacing: 8) {
                    Text(slice.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .frame(width: 170, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(.orange.opacity(0.75))
                            .frame(width: max(3, geo.size.width * CGFloat(slice.work) / CGFloat(top)))
                    }
                    .frame(height: 6)
                    Text(UsageSummary.format(slice.work))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 46, alignment: .trailing)
                }
            }
            let w = summary.week
            Text("Input \(UsageSummary.format(w.input)) · Output \(UsageSummary.format(w.output)) · Cache writes \(UsageSummary.format(w.cacheWrite)) · Cache reads \(UsageSummary.format(w.cacheRead))")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

/// "Show 29 older" / "Show fewer" under Done.
private struct OlderToggle: View {
    @Bindable var app: ChatApp
    let hidden: Int
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { app.showAllCompleted.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(app.showAllCompleted ? 90 : 0))
                Text(app.showAllCompleted ? "Show fewer" : "Show \(hidden) older")
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(hovering ? 0.7 : 0.45))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Filter sessions by name or project.
private struct SessionSearch: View {
    @Bindable var app: ChatApp

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            TextField("Search sessions", text: $app.agentQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .onExitCommand { app.agentQuery = "" }
            if !app.agentQuery.isEmpty {
                Button { app.agentQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.07)))
    }
}

private struct AgentRow: View {
    let app: ChatApp
    let agent: ClaudeAgent
    /// Under a project in the tree (that project's folder): the project name is above it, so only a worktree's
    /// own name shows, or the session's own project when you moved it there.
    var treeFolder: String?
    @State private var hovering = false

    private var ownProject: String { ClaudeAgentsMonitor.projectFolder(agent.cwd) }
    private var isWorktree: Bool { treeFolder != nil && ownProject == treeFolder && agent.cwd != ownProject }

    /// What the second line names the session's folder as, if anything.
    private var folderLabel: String? {
        guard let treeFolder else { return agent.project }
        if agent.cwd == treeFolder { return nil }
        return isWorktree ? agent.project : URL(fileURLWithPath: ownProject).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 9) {
            PhaseMark(phase: agent.phase).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(agent.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if app.unseenAgents.contains(agent.id) {
                        Circle().fill(agent.phase == .needsYou ? .orange : .green).frame(width: 6, height: 6)
                    }
                    if app.terminals[agent.id]?.isRunning == true {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.6))
                            .help("Open in the notch")
                    }
                }
                HStack(spacing: 4) {
                    if let folderLabel {
                        if isWorktree { Image(systemName: "arrow.triangle.branch").font(.system(size: 8)) }
                        Text(folderLabel)
                        Text("·")
                    }
                    Text(agent.kind == .background ? "Background" : "Interactive")
                    if let started = agent.startedAt {
                        Text("·")
                        Text(started, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                Text(agent.kind == .background
                     ? (app.agentOpenMode == .notch ? "Open terminal" : "Attach in Terminal")
                     : "Open in \(app.editor.name)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { app.open(agent) }
        .draggable(agent.id) {
            Label(agent.name, systemImage: "sparkle")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.8)))
                .foregroundStyle(.white)
        }
        .contextMenu {
            if agent.kind == .background {
                Button("Open Terminal in Notch") { app.openInNotch(agent) }
                Button("Attach in New Terminal Window") { app.openInTerminalApp(agent) }
                Divider()
            }
            MoveToFolderMenu(app: app, sessions: [agent.id])
            Divider()
            // In the project itself, not a worktree an earlier session left behind.
            Button("New Agent Here…") { app.composeAgent(in: ownProject) }
            Button("Open Folder in \(app.editor.name)") { app.editor.open(agent.cwd) }
            Button("Open Terminal in Folder") { app.openShell(in: agent.cwd) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: agent.cwd)])
            }
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(agent.id, forType: .string)
            }
            if agent.kind == .background {
                Divider()
                if agent.status != nil && agent.phase != .done {
                    Button("Stop Session") { app.stopSession(agent) }
                }
                Button("Delete Session…", role: .destructive) { app.deleteSession(agent) }
            }
            Divider()
            AskMenuItems { "Claude Code session: \(agent.name)\nProject: \(agent.cwd)\nStatus: \(agent.state ?? agent.status ?? "unknown")" }
        }
    }
}

/// Prompt + project folder + mode → `claude --bg` in that folder. Return starts it (⌥Return for a new line).
private struct NewAgentForm: View {
    let app: ChatApp
    @State private var prompt = ""
    @State private var folder = ""
    @State private var mode = AgentMode.plan
    @State private var starting = false
    @State private var status: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("What should the new Claude Code agent do?", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(start)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1)))
            HStack(spacing: 8) {
                Menu {
                    ForEach(app.agentMonitor.recentFolders, id: \.self) { path in
                        Button(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) { folder = path }
                    }
                    Divider()
                    Button("Choose Folder…", action: chooseFolder)
                } label: {
                    Label(folder.isEmpty ? "Project folder" : URL(fileURLWithPath: folder).lastPathComponent,
                          systemImage: "folder")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                Menu {
                    Picker("Mode", selection: $mode) {
                        ForEach(AgentMode.allCases) { mode in
                            Text("\(mode.name) — \(mode.detail)").tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Label(mode.name, systemImage: mode.systemImage)
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(mode.detail)
                if let status {
                    Text(status).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer()
                Button("Cancel") { app.composingAgent = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                Button(action: start) {
                    HStack(spacing: 4) {
                        if starting { NotchSpinner(size: 9, color: .black, lineWidth: 1.5) }
                        Text("Start")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(.white))
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.15)))
        .onAppear {
            folder = app.newAgentFolder ?? app.agentMonitor.recentFolders.first ?? ""
            app.newAgentFolder = nil
            mode = app.agentMonitor.newAgentMode
            focused = true
        }
        .onChange(of: app.newAgentFolder) { _, picked in
            // New Agent Here on another folder while the form is already open.
            guard let picked else { return }
            folder = picked
            app.newAgentFolder = nil
            focused = true
        }
    }

    private var canStart: Bool {
        !starting && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !folder.isEmpty
    }

    private func chooseFolder() {
        if let path = ChatApp.chooseFolder() { folder = path }
    }

    private func start() {
        guard canStart else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        starting = true
        status = nil
        app.agentMonitor.newAgentMode = mode
        Task {
            defer { starting = false }
            do {
                try await app.agentMonitor.dispatch(prompt: text, in: folder, mode: mode)
                prompt = ""
                app.composingAgent = false
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
