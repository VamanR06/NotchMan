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
                ForEach($app.templates) { $template in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Name", text: $template.name).fontWeight(.medium)
                            Button(role: .destructive) {
                                app.templates.removeAll { $0.id == template.id }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
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
