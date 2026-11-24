import NotchKit
import SwiftUI

/// Settings → Prompts: every prompt NotchMan sends to a model, grouped by where it's used, each editable with a
/// way back to the default. Edits apply to the next request; nothing needs restarting.
struct PromptsSettingsView: View {
    let prompts: [EditablePrompt]

    /// Groups in the order their first prompt appears.
    private var groups: [(name: String, prompts: [EditablePrompt])] {
        var order: [String] = []
        var byGroup: [String: [EditablePrompt]] = [:]
        for prompt in prompts {
            if byGroup[prompt.group] == nil { order.append(prompt.group) }
            byGroup[prompt.group, default: []].append(prompt)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    var body: some View {
        Form {
            ForEach(groups, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.prompts) { PromptEditorRow(prompt: $0) }
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text("Edits are used from the next request on. Words in {braces} are filled in when the prompt is sent; if you delete a required one, its text is added at the end. The ChatGPT prompts for jobs are in Jobs settings, and the Ask AI template is in Chat settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PromptEditorRow: View {
    let prompt: EditablePrompt
    @State private var text: String
    @State private var expanded = false

    init(prompt: EditablePrompt) {
        self.prompt = prompt
        _text = State(initialValue: prompt.text)
    }

    private var edited: Bool { text != prompt.defaultText && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(prompt.detail).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120, maxHeight: prompt.defaultText.count > 2_000 ? 360 : 220)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                    .onChange(of: text) { _, new in prompt.setText(new) }
                HStack(alignment: .top) {
                    if !prompt.placeholders.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(prompt.placeholders, id: \.name) { placeholder in
                                Text("\(placeholder.token): \(placeholder.meaning)\(placeholder.required ? "" : " (optional)")")
                            }
                        }
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Restore Default") { text = prompt.defaultText }
                        .disabled(!edited)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text(prompt.title)
                if edited {
                    Text("Edited")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}
