import SwiftUI

struct JobsSettingsView: View {
    @Bindable var app: JobsApp
    @State private var server = ""
    @State private var password = ""
    @State private var signingIn = false
    @State private var signInError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Jobs when the browser shows a tracked job", isOn: $app.opensOnJobPages)
                Toggle("Mark a job Applied when the site confirms you submitted", isOn: $app.marksAppliedOnSubmit)
            } header: {
                Text("On a job's page")
            } footer: {
                Text("Hovering the notch open on a job you track (its posting or application form) shows it in Jobs with its resume and cover letter to drag onto the page, and Autofill, which fills the form with your JobManager Profile and saved answers (never submits). Autofill needs your browser to allow it once: Chrome, Arc, Brave, Edge → View → Developer → Allow JavaScript from Apple Events; Safari → Develop → Allow JavaScript from Apple Events. Once Jobs has shown a job you haven't applied to, it watches that tab for half an hour: when the site says it got your application (and the form is gone), the job moves to Applied, with Undo.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if app.isSignedIn {
                    LabeledContent("Server", value: app.client.serverURL)
                    LabeledContent("Status") {
                        HStack {
                            Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Sign Out") { app.signOut() }
                        }
                    }
                    if let error = app.error {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                } else {
                    TextField("Server URL", text: $server)
                    SecureField("Password", text: $password)
                        .onSubmit(signIn)
                    HStack {
                        Button("Sign In", action: signIn)
                            .disabled(server.isEmpty || signingIn)
                        if signingIn { ProgressView().controlSize(.small) }
                    }
                    if let signInError {
                        Text(signInError).foregroundStyle(.red).font(.caption)
                    }
                }
            } header: {
                Text("JobManager")
            } footer: {
                Text("""
                Reads your applications from JobManager. The password is stored in your Keychain so NotchMan can \
                sign in again when the 30-day session ends. For a local copy with no password, use \
                http://localhost:3000 and leave the password empty.
                """)
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Default ChatGPT project", text: $app.defaultProjectURL, prompt: Text("https://chatgpt.com/g/g-p-…/project"))
                if !app.defaultProjectURL.isEmpty && !PromptTemplate.isChatGPTLink(app.defaultProjectURL) {
                    Text("That isn't a chatgpt.com link, so chats will start as normal new chats.")
                        .foregroundStyle(.orange).font(.caption)
                }
            } header: {
                Text("ChatGPT Project")
            } footer: {
                Text("Chats from the ✨ menu start in this project, so they're saved there. Open the project in ChatGPT and copy its URL from the address bar. Leave empty for normal new chats.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach($app.templates) { $template in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Name", text: $template.name).fontWeight(.medium)
                            Button(role: .destructive) {
                                app.templates.removeAll { $0.id == template.id }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                        TextField("Project (optional)", text: Binding(
                            get: { template.projectURL ?? "" },
                            set: { template.projectURL = $0.isEmpty ? nil : $0 }
                        ), prompt: Text("Uses the default project"))
                        .font(.system(size: 11))
                        TextEditor(text: $template.text)
                            .font(.system(size: 12))
                            .frame(minHeight: 90)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                    }
                    .padding(.vertical, 4)
                }
                HStack {
                    Button("Add Prompt") {
                        app.templates.append(PromptTemplate(name: "New prompt", text: "Help me apply to {title} at {company}.\n\n{posting}"))
                    }
                    Button("Restore Defaults") { app.templates = PromptTemplate.defaults }
                }
            } header: {
                Text("ChatGPT Prompts")
            } footer: {
                Text("Shown in the ✨ menu on jobs you haven't applied to yet. Picking one opens a new ChatGPT chat in the notch with the prompt typed in (not sent). Placeholders: \(PromptTemplate.placeholders.joined(separator: " ")). {posting} is the job description saved in JobManager.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { server = app.client.serverURL }
    }

    private func signIn() {
        signingIn = true
        signInError = nil
        let password = self.password
        Task {
            defer { signingIn = false }
            do {
                try await app.signIn(server: server, password: password)
                self.password = ""
            } catch {
                signInError = error.localizedDescription
            }
        }
    }
}
