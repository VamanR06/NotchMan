import SwiftUI

struct ClockSettingsView: View {
    let app: ClockApp
    @State private var search = ""

    var body: some View {
        Form {
            Section {
                if app.worldClocks.isEmpty {
                    Text("No cities yet.").foregroundStyle(.secondary)
                }
                List {
                    ForEach(app.worldClocks, id: \.self) { identifier in
                        HStack {
                            Text(ClockFormat.city(identifier))
                            Text(identifier).foregroundStyle(.secondary).font(.caption)
                            Spacer()
                            Button { app.removeWorldClock(identifier) } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onMove(perform: app.moveWorldClocks)
                }
            } header: {
                Text("World Clocks")
            } footer: {
                Text("Shown beside the local time on the Clock tab. Drag to reorder.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Add a City") {
                TextField("Search cities or time zones", text: $search)
                ForEach(matches, id: \.self) { identifier in
                    Button {
                        app.addWorldClock(identifier)
                        search = ""
                    } label: {
                        HStack {
                            Text(ClockFormat.city(identifier))
                            Text(identifier).foregroundStyle(.secondary).font(.caption)
                            Spacer()
                            Image(systemName: "plus.circle")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Time zones whose city or identifier contains the search (spaces match underscores), up to 8.
    private var matches: [String] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        return TimeZone.knownTimeZoneIdentifiers
            .filter { !app.worldClocks.contains($0) && $0.lowercased().replacingOccurrences(of: "_", with: " ").contains(query) }
            .prefix(8)
            .map { $0 }
    }
}
