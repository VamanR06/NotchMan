import AppKit
import NotchKit
import SwiftUI

/// The Agents app's Overview: the three web chats at a glance, then Claude Code agents by phase.
struct AgentsOverview: View {
    @Bindable var app: ChatApp

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChatStrip(app: app)
            if app.composingAgent {
                NewAgentForm(app: app)
            }
            AgentList(app: app)
        }
        .onAppear { app.markOverviewSeen() }
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
        ForEach([ClaudeAgent.Phase.needsYou, .working, .done, .idle], id: \.self) { phase in
            let agents = app.agentMonitor.agents.filter { $0.phase == phase }
            if !agents.isEmpty {
                Section {
                    ForEach(agents) { AgentRow(app: app, agent: $0) }
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

    private func title(_ phase: ClaudeAgent.Phase) -> String {
        switch phase {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .done: "Done"
        case .idle: "Idle"
        }
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
                Text(agent.kind == .background ? "Attach" : "Open in \(app.editor.name)")
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
                Button("Attach in Terminal") { Task { await app.agentMonitor.attach(agent) } }
            }
            Button("Open Folder in \(app.editor.name)") { app.editor.open(agent.cwd) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: agent.cwd)])
            }
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(agent.id, forType: .string)
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

/// Prompt + project folder → `claude --bg` in that folder.
private struct NewAgentForm: View {
    let app: ChatApp
    @State private var prompt = ""
    @State private var folder = ""
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
                .disabled(starting || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || folder.isEmpty)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.15)))
        .onAppear {
            folder = app.agentMonitor.recentFolders.first ?? ""
            focused = true
        }
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
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        starting = true
        status = nil
        Task {
            defer { starting = false }
            do {
                try await app.agentMonitor.dispatch(prompt: text, in: folder)
                prompt = ""
                app.composingAgent = false
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
