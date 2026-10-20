import AppKit
import SwiftUI

struct NowPlayingSettingsView: View {
    let app: NowPlayingApp
    @Bindable var library: SpotifyLibrary
    @State private var clientID = ""
    @State private var signInError: String?

    var body: some View {
        Form {
            Section {
                if library.isSignedIn {
                    LabeledContent("Status") {
                        HStack {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Disconnect") { library.signOut() }
                        }
                    }
                    LabeledContent("Playlists", value: "\(library.playlists.count)")
                    Button("Reload Playlists") { Task { await app.loadPlaylists() } }
                } else {
                    TextField("Client ID", text: $clientID)
                    LabeledContent("Redirect URI") {
                        HStack {
                            Text(SpotifyLibrary.redirectURI).textSelection(.enabled).font(.system(.body, design: .monospaced))
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(SpotifyLibrary.redirectURI, forType: .string)
                            }
                        }
                    }
                    HStack {
                        if library.isSigningIn {
                            ProgressView().controlSize(.small)
                            Text("Waiting for browser…").foregroundStyle(.secondary)
                            Button("Cancel") { library.cancelSignIn() }
                        } else {
                            Button("Connect Spotify", action: connect).disabled(clientID.isEmpty)
                        }
                    }
                }
                if let message = signInError ?? app.libraryError {
                    Text(message).foregroundStyle(.red).font(.caption)
                }
            } header: {
                Text("Spotify Playlists")
            } footer: {
                Text("""
                One-time setup (needs Spotify Premium): at developer.spotify.com/dashboard create an app, add the \
                Redirect URI above exactly, tick "Web API", and paste the app's Client ID here. No client secret is \
                needed. Playback itself goes through the Spotify app.
                """)
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { clientID = library.clientID }
    }

    private func connect() {
        library.clientID = clientID
        signInError = nil
        Task {
            do {
                try await library.signIn()
                await app.loadPlaylists()
            } catch {
                signInError = error.localizedDescription
            }
        }
    }
}
