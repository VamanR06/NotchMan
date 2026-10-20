import NotchKit
import SwiftUI

struct ChatSettingsView: View {
    @Bindable var app: ChatApp
    @State private var template = AskAI.shared.promptTemplate

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $app.notifyWhenDone) {
                    Text("Notify when a reply finishes")
                    Text("A macOS notification when ChatGPT, Claude or Muse finishes a reply (3 seconds or longer) while the chat isn't on screen. The notch always shows a ✓ until you look.")
                }
            } header: {
                Text("Notifications")
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
                        Text(project.name)
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
            Text("\"Load\" reads the project names and links from \(service.name)'s sidebar in the notch (sign in there first; if none are found, open the sidebar or pop the chat out and try again). You can also paste a project's link from the address bar.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() {
        loading = true
        status = nil
        Task {
            defer { loading = false }
            do {
                let added = try await app.loadProjects(for: service)
                status = added == 0 ? "No new projects found." : "Added \(added) project\(added == 1 ? "" : "s")."
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
