import Foundation

/// A prompt NotchMan sends to a model, which you can rewrite in Settings → Prompts.
///
/// Apps list theirs in `NotchApp.prompts`. Code reads `text` (your version, else the default) or `render(_:)` to
/// fill `{placeholders}`. A required placeholder you deleted is added at the end, so a prompt never loses its data.
public struct EditablePrompt: Identifiable, Hashable, Sendable {
    public struct Placeholder: Hashable, Sendable {
        public let name: String
        public let meaning: String
        /// Added at the end of the prompt if you remove it.
        public let required: Bool

        public init(_ name: String, _ meaning: String, required: Bool = true) {
            self.name = name
            self.meaning = meaning
            self.required = required
        }

        public var token: String { "{\(name)}" }
    }

    public let id: String
    /// Where it's used, as Settings groups it ("Jobs", "Agents").
    public let group: String
    public let title: String
    /// What it's for and which model reads it.
    public let detail: String
    public let placeholders: [Placeholder]
    public let defaultText: String

    public init(id: String, group: String, title: String, detail: String, placeholders: [Placeholder] = [], defaultText: String) {
        self.id = id
        self.group = group
        self.title = title
        self.detail = detail
        self.placeholders = placeholders
        self.defaultText = defaultText
    }

    // MARK: Your version

    /// Where edits are kept (shared by every app).
    public static var store: UserDefaults { UserDefaults(suiteName: "com.notchman.prompts") ?? .standard }

    private var key: String { "prompt.\(id)" }

    /// The text in use: your edit, or the default when there's none (or it's blank).
    public func text(in store: UserDefaults = EditablePrompt.store) -> String {
        guard let edited = store.string(forKey: key), !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultText
        }
        return edited
    }

    public var text: String { text() }

    public func isEdited(in store: UserDefaults = EditablePrompt.store) -> Bool { text(in: store) != defaultText }

    /// Saves `text` as your version; nil, blank or the default itself goes back to the default.
    public func setText(_ text: String?, in store: UserDefaults = EditablePrompt.store) {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != defaultText {
            store.set(text, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }

    // MARK: Filling it in

    /// The text in use with each `{name}` replaced by `values[name]`.
    public func render(_ values: [String: String], in store: UserDefaults = EditablePrompt.store) -> String {
        Self.fill(text(in: store), placeholders: placeholders, values: values)
    }

    static func fill(_ template: String, placeholders: [Placeholder], values: [String: String]) -> String {
        // Empty placeholders first, then squeeze the blank lines they leave, in the template only (never in the data).
        var result = template
        for placeholder in placeholders where (values[placeholder.name] ?? "").isEmpty {
            result = result.replacingOccurrences(of: placeholder.token, with: "")
        }
        while result.contains("\n\n\n") { result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        var missing: [String] = []
        for placeholder in placeholders {
            guard let value = values[placeholder.name], !value.isEmpty else { continue }
            if result.contains(placeholder.token) {
                result = result.replacingOccurrences(of: placeholder.token, with: value)
            } else if placeholder.required {
                missing.append(value)
            }
        }
        return ([result] + missing).joined(separator: "\n\n")
    }
}
