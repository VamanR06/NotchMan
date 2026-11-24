import AppKit
import SwiftUI
import Testing
import NotchKit
@testable import NotchEngine

@MainActor @Suite struct PromptsSettingsTests {
    /// Renders Settings → Prompts into build/dev for eyeballing (through a hosting view: the Form is AppKit).
    @Test func rendersPromptsPane() throws {
        let prompts = [
            EditablePrompt(id: "render.jobs", group: "Jobs", title: "Answer drafts",
                           detail: "How the Ollama model writes answers to a form's open questions.", defaultText: "You draft answers…"),
            EditablePrompt(id: "render.bar", group: "Command bar", title: "Answering a request", detail: "",
                           placeholders: [.init("request", "what you typed")], defaultText: "Request: {request}"),
            EditablePrompt(id: "render.stuck", group: "Agents", title: "Why an agent looks stuck", detail: "", defaultText: "x"),
            EditablePrompt(id: "render.approval", group: "Agents", title: "Explaining a permission request", detail: "", defaultText: "y"),
        ]
        let host = NSHostingView(rootView: PromptsSettingsView(prompts: prompts).frame(width: 520, height: 420)
            .environment(\.colorScheme, .dark))
        host.frame = CGRect(x: 0, y: 0, width: 520, height: 420)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../build/dev").standardizedFileURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appending(path: "prompts-settings.png"))
    }
}
