import AppKit
import NotchKit
import SwiftUI

/// The Agents app's Overview: the three web chats at a glance, then Claude Code agents by phase.
struct AgentsOverview: View {
    @Bindable var app: ChatApp

    var body: some View {
        if let terminal = app.shownTerminal {
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
                SessionSearch(app: app)
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

/// ChatGPT / Claude / Muse status pills; click to open that chat.
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
                AgentSections(app: app, lazy: true)
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
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            phaseMark.frame(width: 14)
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
                    Text(agent.project)
                    Text("·")
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
        .contextMenu {
            if agent.kind == .background {
                Button("Open Terminal in Notch") { app.openInNotch(agent) }
                Button("Attach in New Terminal Window") { app.openInTerminalApp(agent) }
                Divider()
            }
            Button("Open Folder in \(app.editor.name)") { app.editor.open(agent.cwd) }
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

    @ViewBuilder
    private var phaseMark: some View {
        switch agent.phase {
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
            folder = app.agentMonitor.recentFolders.first ?? ""
            mode = app.agentMonitor.newAgentMode
            focused = true
        }
    }

    private var canStart: Bool {
        !starting && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !folder.isEmpty
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
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
