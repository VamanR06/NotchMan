import NotchKit
import SwiftUI

struct ChatSettingsView: View {
    @Bindable var app: ChatApp
    @State private var template = AskAI.shared.promptTemplate
    @State private var claudePath = ""
    @State private var detectedPath: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $app.notifyWhenDone) {
                    Text("Notify about agents and chats")
                    Text("A macOS notification when a Claude Code agent needs you or finishes, or when ChatGPT, Claude or Muse finishes a reply (3 seconds or longer), while you aren't looking at it. The notch always shows it until you look.")
                }
            } header: {
                Text("Notifications")
            }

            Section {
                Picker("Clicking a background agent opens", selection: $app.agentOpenMode) {
                    ForEach(ChatApp.AgentOpenMode.allCases) { Text($0.name).tag($0) }
                }
                Picker("Open interactive sessions in", selection: $app.editor) {
                    ForEach(AgentEditor.allCases) { Text($0.name).tag($0) }
                }
                TextField("claude command", text: $claudePath, prompt: Text(detectedPath ?? "Auto-detect"))
                    .onSubmit { app.agentMonitor.claudePathOverride = claudePath; refreshDetected() }
                if let error = app.agentMonitor.error {
                    Text(error).foregroundStyle(.orange).font(.caption)
                }
            } header: {
                Text("Claude Code Agents")
            } footer: {
                Text("The Overview lists sessions from `claude agents --json` (CLI, VS Code and background agents on this Mac). Clicking a background agent attaches to it in a terminal inside the notch (or a new Terminal window); right-click offers both. An interactive one opens its folder in your editor. Leave the command empty to find it automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Approval hook") {
                    HStack {
                        if app.approvalHookInstalled {
                            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Remove") { app.setApprovalHookInstalled(false) }
                        } else {
                            Button("Install Approval Hook") { app.setApprovalHookInstalled(true) }
                        }
                    }
                }
                Picker("Wait in the notch for", selection: $app.approvalWait) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
                .onChange(of: app.approvalWait) { _, _ in app.approvalWaitChanged() }
                Toggle("Also ask for interactive sessions", isOn: $app.approvalsForAllSessions)
                if let error = app.approvalHookError {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            } header: {
                Text("Approvals")
            } footer: {
                Text("When a background agent wants permission for a tool, Allow / Deny shows on the notch chip, in Today, on the Overview and in the notification. Claude Code waits for NotchMan first, so if you don't answer within the wait (or NotchMan isn't running) it asks in its terminal as usual. Risky-looking commands (rm -rf, sudo, force-push, curl | sh…) are marked red; nothing is ever allowed automatically. Installing adds an HTTP hook to ~/.claude/settings.json next to your other hooks and saves a backup as settings.json.notchman-backup.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $template)
                    .font(.system(size: 12))
                    .frame(minHeight: 60)
                    .onChange(of: template) { _, value in app.askTemplate = value }
                Button("Restore Default") { template = AskAI.defaultTemplate }
            } header: {
                Text("Ask from Anywhere")
            } footer: {
                Text("Right-click an event, task, job, song or playlist in the notch and pick Ask ChatGPT, Claude or Muse. This prompt is typed into a new chat (not sent); {item} becomes the details of what you right-clicked.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach(ChatService.allCases.filter(\.supportsProjects)) { service in
                ProjectsSection(app: app, service: service)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            claudePath = app.agentMonitor.claudePathOverride
            refreshDetected()
        }
    }

    private func refreshDetected() {
        Task { detectedPath = await app.agentMonitor.claudePath() }
    }
}

private struct ProjectsSection: View {
    let app: ChatApp
    let service: ChatService
    @State private var newName = ""
    @State private var newURL = ""
    @State private var status: String?
    @State private var loading = false

    private var projects: [AskProject] { app.projects[service] ?? [] }

    var body: some View {
        Section {
            Picker("Default project", selection: Binding(
                get: { app.defaultProjects[service] ?? "" },
                set: { app.setDefaultProject($0.isEmpty ? nil : $0, for: service) }
            )) {
                Text("None (normal new chat)").tag("")
                ForEach(projects) { Text($0.name).tag($0.url) }
            }

            ForEach(projects) { project in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        TextField("Name", text: Binding(
                            get: { project.name },
                            set: { rename(project, to: $0) }
                        ))
                        .textFieldStyle(.plain)
                        .help("Click to rename")
                        Text(project.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        app.setProjects(projects.filter { $0.url != project.url }, for: service)
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                TextField("Name", text: $newName).frame(maxWidth: 160)
                TextField("Project link", text: $newURL)
                Button("Add") {
                    guard let url = service.page(newURL) else {
                        status = "That isn't a \(service.home.host() ?? "") link."
                        return
                    }
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    app.setProjects(projects + [AskProject(name: name.isEmpty ? url.lastPathComponent : name, url: url.absoluteString)], for: service)
                    newName = ""
                    newURL = ""
                    status = nil
                }
                .disabled(newURL.isEmpty)
            }

            HStack {
                Button("Load from \(service.name)") { load() }.disabled(loading)
                if loading { ProgressView().controlSize(.small) }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        } header: {
            Text("\(service.name) Projects")
        } footer: {
            Text("\"Load\" reads your project names and links from \(service.name) (a hidden desktop-size copy of the site, using your sign-in from the notch — sign in there first). Or paste a project's link from the address bar.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func rename(_ project: AskProject, to name: String) {
        app.setProjects(projects.map { $0.url == project.url ? AskProject(name: name, url: $0.url) : $0 }, for: service)
    }

    private func load() {
        loading = true
        status = nil
        Task {
            defer { loading = false }
            do {
                status = try await app.loadProjects(for: service).message
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
