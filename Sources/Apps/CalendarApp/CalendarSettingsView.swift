import SwiftUI

struct CalendarSettingsView: View {
    let app: CalendarApp
    @Bindable var google: GoogleCalendarSource

    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var googleError: String?

    var body: some View {
        Form {
            googleSection
        }
        .formStyle(.grouped)
        .onAppear {
            clientID = google.clientID
            clientSecret = google.clientSecret
        }
        .task {
            if google.isSignedIn, google.calendars.isEmpty { try? await google.loadCalendars() }
        }
    }

    // MARK: Google

    @ViewBuilder
    private var googleSection: some View {
        Section {
            if google.isSignedIn {
                LabeledContent("Status") {
                    HStack {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Sign Out") { google.signOut(); refreshTimeline() }
                    }
                }
                if !google.canEditEvents {
                    LabeledContent("Rescheduling") {
                        HStack {
                            Text("Needs permission to change events").foregroundStyle(.secondary)
                            Button(google.isSigningIn ? "Waiting for browser…" : "Reconnect") { signInGoogle() }
                                .disabled(google.isSigningIn)
                        }
                    }
                }
                ForEach(google.calendars) { calendar in
                    Toggle(isOn: Binding(
                        get: { !google.hiddenCalendarIDs.contains(calendar.id) },
                        set: { visible in
                            if visible { google.hiddenCalendarIDs.remove(calendar.id) } else { google.hiddenCalendarIDs.insert(calendar.id) }
                            refreshTimeline()
                        }
                    )) {
                        Label {
                            Text(calendar.name)
                        } icon: {
                            Circle().fill(calendar.color).frame(width: 10, height: 10)
                        }
                    }
                }
            } else {
                TextField("OAuth Client ID", text: $clientID)
                SecureField("OAuth Client Secret", text: $clientSecret)
                HStack {
                    if google.isSigningIn {
                        ProgressView().controlSize(.small)
                        Text("Waiting for browser…").foregroundStyle(.secondary)
                        Button("Cancel") { google.cancelSignIn() }
                    } else {
                        Button("Sign in with Google") { signInGoogle() }
                            .disabled(clientID.isEmpty || clientSecret.isEmpty)
                    }
                }
            }
            if let googleError {
                Text(googleError).foregroundStyle(.red).font(.caption)
            }
        } header: {
            Text("Google Calendar")
        } footer: {
            if !google.isSignedIn {
                Text("""
                One-time, free setup: in Google Cloud Console create a project, enable the Google Calendar API, \
                configure the OAuth consent screen (External, then "Publish app" so sign-in doesn't expire weekly), \
                and create an OAuth client of type "Desktop app". Paste its ID and secret here. \
                Events open in Notion Calendar when it's installed (right-click for Google Calendar).
                """)
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func signInGoogle() {
        google.clientID = clientID
        google.clientSecret = clientSecret
        googleError = nil
        Task {
            do {
                try await google.signIn()
                await app.refresh()
            } catch {
                googleError = error.localizedDescription
            }
        }
    }

    private func refreshTimeline() {
        Task { await app.refresh() }
    }
}
