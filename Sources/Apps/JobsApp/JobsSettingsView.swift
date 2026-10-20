import SwiftUI

struct JobsSettingsView: View {
    let app: JobsApp
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
