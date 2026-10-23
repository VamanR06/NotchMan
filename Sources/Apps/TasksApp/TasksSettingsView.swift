import SwiftUI

struct TasksSettingsView: View {
    let app: TasksApp
    @State private var token = ""

    var body: some View {
        Form {
            Section {
                if app.isConnected {
                    LabeledContent("Status") {
                        HStack {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Disconnect") { app.disconnect() }
                        }
                    }
                } else {
                    SecureField("Internal integration secret", text: $token)
                    Button("Connect Notion") {
                        let value = token
                        token = ""
                        Task { await app.connect(token: value) }
                    }
                    .disabled(token.isEmpty)
                }
                if let error = app.error {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            } header: {
                Text("Notion")
            } footer: {
                Text("""
                Create a free internal integration at notion.so/profile/integrations (with Read and Update content), \
                paste its secret, then share each task database with it via ••• → Connections.
                """)
                .font(.caption).foregroundStyle(.secondary)
            }

            if app.isConnected {
                Section {
                    if app.databases.isEmpty {
                        Text(app.isLoading ? "Loading…" : "No databases shared with the integration yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(app.databases) { db in
                        DatabaseSettings(app: app, db: db)
                    }
                    if !app.enabledDatabases.isEmpty {
                        Picker("Quick add goes to", selection: Binding(
                            get: { app.quickAddDatabaseID.isEmpty ? app.enabledDatabases[0].id : app.quickAddDatabaseID },
                            set: { app.quickAddDatabaseID = $0 }
                        )) {
                            ForEach(app.enabledDatabases) { Text($0.title).tag($0.id) }
                        }
                    }
                    Button("Reload Databases") { Task { await app.refresh() } }
                } header: {
                    Text("Task Databases")
                } footer: {
                    Text("Due date places tasks in Overdue / Today / Upcoming. Done is what the checkbox sets; done tasks are hidden. Quick add (Today app) uses the list above, or another whose name you tag, e.g. “#school”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await app.refreshIfStale() }
    }
}

private struct DatabaseSettings: View {
    let app: TasksApp
    let db: TaskDatabase

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { app.isEnabled(db) }, set: { app.setEnabled(db, $0) })) {
                Text(db.title).fontWeight(.medium)
            }
            if app.isEnabled(db) {
                Picker("Due date", selection: Binding(
                    get: { app.dueProperty(for: db) ?? "" },
                    set: { app.setDueProperty($0.isEmpty ? nil : $0, for: db) }
                )) {
                    Text("None").tag("")
                    ForEach(db.dateProperties, id: \.self) { Text($0).tag($0) }
                }
                Picker("Done", selection: Binding(
                    get: { app.doneRule(for: db)?.property ?? "" },
                    set: { app.setDoneProperty($0.isEmpty ? nil : $0, for: db) }
                )) {
                    Text("None (show all, no check-off)").tag("")
                    ForEach(db.doneRules, id: \.property) { Text($0.label).tag($0.property) }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
