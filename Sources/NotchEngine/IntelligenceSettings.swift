import AppKit
import NotchKit
import SwiftUI

/// Settings → Intelligence: Jev's API key, how much leaves the Mac, your identity for redaction, a redaction preview,
/// and every request as it was sent.
struct IntelligenceSettingsView: View {
    @State private var keyDraft = ""
    @State private var hasKey = JevSettings.apiKey != nil
    @State private var privacy = JevSettings.privacy
    @State private var identity = JevSettings.identity.joined(separator: ", ")
    @State private var sample = "Jane_Doe_Resume_2026.pdf, sent to recruiter@acme.io"
    @State private var testResult: String?
    @State private var testing = false
    @State private var log = JevLog.shared
    @State private var expanded: UUID?

    var body: some View {
        Form {
            Section {
                LabeledContent("API key") {
                    if hasKey {
                        HStack {
                            Label("Saved in the Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Remove") {
                                JevSettings.apiKey = nil
                                hasKey = false
                            }
                        }
                    } else {
                        HStack {
                            SecureField("TypeSafe API key", text: $keyDraft).frame(width: 240)
                            Button("Save") {
                                JevSettings.apiKey = keyDraft
                                keyDraft = ""
                                hasKey = JevSettings.apiKey != nil
                            }
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                Picker(selection: $privacy) {
                    ForEach(JevPrivacy.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    Text("What's sent")
                    Text(privacyNote)
                }
                .onChange(of: privacy) { _, value in JevSettings.privacy = value }
                LabeledContent("Check") {
                    HStack {
                        Button(testing ? "Asking…" : "Test") { Task { await test() } }
                            .disabled(testing || !hasKey || privacy == .off)
                        if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            } header: {
                Text("Jev")
            } footer: {
                Text("Jev (TypeSafe's fast decision model) turns what you type in the command bar into an app's action, and helps the Shelf with file types you've never filed before. Where you've put files before always counts most.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Your name, email, username…", text: $identity, axis: .vertical)
                    .lineLimit(1...3)
                    .onSubmit(saveIdentity)
                HStack {
                    Button("Save") { saveIdentity() }
                    Button("Use my account's name") {
                        identity = Redactor.defaultIdentity().joined(separator: ", ")
                        saveIdentity()
                    }
                }
                TextField("Try some text", text: $sample, axis: .vertical).lineLimit(1...3)
                LabeledContent("Sent as") {
                    Text(previewText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("Redaction")
            } footer: {
                Text("Your identity is replaced with MY_NAME / MY_EMAIL / MY_USERNAME. Other people, emails, phone numbers, addresses, card and ID numbers, and keys become placeholders like PERSON_1 or EMAIL_1. Paths start at ~, web addresses keep only the site, and file contents are never sent. If anything personal is still found just before sending, the request is held back.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if log.entries.isEmpty {
                    Text("Nothing sent yet.").foregroundStyle(.secondary)
                }
                ForEach(log.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.date.formatted(date: .omitted, time: .standard)).monospacedDigit()
                            Text(entry.outcome)
                                .foregroundStyle(entry.outcome.hasPrefix("200") ? Color.secondary : Color.orange)
                            Spacer()
                            Button(expanded == entry.id ? "Hide" : "Show") {
                                expanded = expanded == entry.id ? nil : entry.id
                            }
                            .buttonStyle(.link)
                        }
                        .font(.caption)
                        if expanded == entry.id {
                            Text(Self.pretty(entry.body))
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if !log.entries.isEmpty {
                    Button("Clear") { log.clear() }
                }
            } header: {
                Text("What was sent")
            } footer: {
                Text("The last 50 requests exactly as they left this Mac (and any held back), kept only while NotchMan runs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var privacyNote: String {
        switch privacy {
        case .off: "Nothing leaves your Mac; suggestions use NotchMan's own rules."
        case .redacted: "Personal details are replaced on your Mac before anything is sent."
        case .full: "File and folder names are sent as they are."
        }
    }

    private var previewText: String {
        let redactor = Redactor(identity: identityList, enabled: privacy != .full)
        return redactor.text(sample)
    }

    private var identityList: [String] {
        identity.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func saveIdentity() {
        JevSettings.identity = identityList
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let started = Date()
        do {
            let answers = try await Jev.ask(state: ["file": ["name": "Resume_2026.pdf", "extension": "pdf"]],
                                            questions: ["resume": .noul("Is the file in `file` a résumé?")])
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if case .noul(let p) = answers["resume"] {
                testResult = "Working: \(ms) ms (résumé? \(Int(p * 100))%)"
            } else {
                testResult = "Answered in \(ms) ms"
            }
        } catch {
            testResult = error.localizedDescription
        }
    }

    static func pretty(_ json: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys,
                                                                                         .withoutEscapingSlashes]) else {
            return json
        }
        return String(decoding: data, as: UTF8.self)
    }
}
