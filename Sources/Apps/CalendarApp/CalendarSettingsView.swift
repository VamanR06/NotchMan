import SwiftUI

struct CalendarSettingsView: View {
    let app: CalendarApp
    @Bindable var google: GoogleCalendarSource
    @Bindable var notion: NotionSource

    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var notionToken = ""
    @State private var googleError: String?
    @State private var notionError: String?
    @State private var loadingDatabases = false

    var body: some View {
        Form {
            googleSection
            notionSection
        }
        .formStyle(.grouped)
        .onAppear {
            clientID = google.clientID
            clientSecret = google.clientSecret
        }
        .task {
            if google.isSignedIn, google.calendars.isEmpty { try? await google.loadCalendars() }
            if notion.hasToken, notion.databases.isEmpty { await loadDatabases() }
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
                and create an OAuth client of type "Desktop app". Paste its ID and secret here.
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

    // MARK: Notion

    @ViewBuilder
    private var notionSection: some View {
        Section {
            if notion.hasToken {
                LabeledContent("Status") {
                    HStack {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Disconnect") { notion.setToken(nil); refreshTimeline() }
                    }
                }
                if loadingDatabases {
                    ProgressView().controlSize(.small)
                } else if notion.databases.isEmpty {
                    Text("No databases found. Share a database with your integration via ••• → Connections.")
                        .foregroundStyle(.secondary)
                }
                ForEach(notion.databases) { db in
                    NotionDatabaseRow(db: db, notion: notion, onChange: refreshTimeline)
                }
                Button("Reload Databases") { Task { await loadDatabases() } }
            } else {
                SecureField("Internal integration secret", text: $notionToken)
                Button("Connect Notion") {
                    notion.setToken(notionToken)
                    notionToken = ""
                    Task { await loadDatabases() }
                }
                .disabled(notionToken.isEmpty)
            }
            if let notionError {
                Text(notionError).foregroundStyle(.red).font(.caption)
            }
        } header: {
            Text("Notion")
        } footer: {
            Text("""
            Create a free internal integration at notion.so/profile/integrations, paste its secret, then share \
            the databases you want with it. Pick which date property places each page on the timeline. \
            Google events can also be opened in Notion Calendar (right-click an event).
            """)
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func loadDatabases() async {
        loadingDatabases = true
        defer { loadingDatabases = false }
        do {
            try await notion.loadDatabases()
            notionError = nil
        } catch {
            notionError = error.localizedDescription
        }
    }

    private func refreshTimeline() {
        Task { await app.refresh() }
    }
}

private struct NotionDatabaseRow: View {
    let db: NotionSource.DatabaseInfo
    @Bindable var notion: NotionSource
    let onChange: () -> Void

    var body: some View {
        if db.dateProperties.isEmpty {
            LabeledContent(db.title) {
                Text("No date property").foregroundStyle(.secondary)
            }
        } else {
            HStack {
                Toggle(db.title, isOn: Binding(
                    get: { notion.selection[db.id] != nil },
                    set: { enabled in
                        notion.selection[db.id] = enabled ? db.dateProperties[0] : nil
                        onChange()
                    }
                ))
                if let current = notion.selection[db.id], db.dateProperties.count > 1 {
                    Picker("", selection: Binding(
                        get: { current },
                        set: { notion.selection[db.id] = $0; onChange() }
                    )) {
                        ForEach(db.dateProperties, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }
}
