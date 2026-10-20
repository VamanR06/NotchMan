import SwiftUI

/// A ChatGPT or Claude project a chat can be started in.
public struct AskProject: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var url: String
    public var id: String { url }

    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }
}

/// A chat service that can be asked about things, with its projects.
public struct AskService: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public var projects: [AskProject]
    public var defaultProjectURL: String?

    public init(id: String, name: String, projects: [AskProject] = [], defaultProjectURL: String? = nil) {
        self.id = id
        self.name = name
        self.projects = projects
        self.defaultProjectURL = defaultProjectURL
    }

    public var defaultProject: AskProject? {
        projects.first { $0.url == defaultProjectURL }
    }
}

/// "Ask ChatGPT / Claude / Muse" from anywhere in the notch.
///
/// Apps mark things with `.askable { "text describing the thing" }` (or put `AskMenuItems` in an existing
/// context menu). The Chat app publishes its services and projects here; the engine routes requests to it.
@MainActor @Observable
public final class AskAI {
    public static let shared = AskAI()

    /// Published by the Chat app.
    public var services: [AskService] = []
    /// `{item}` is replaced with the asked-about text.
    public var promptTemplate = AskAI.defaultTemplate
    public static let defaultTemplate = "Help me with this:\n\n{item}"

    /// Set by the engine: delivers the prompt to the Chat app.
    @ObservationIgnored public var deliver: ((NotchMessage) -> Void)?

    public init() {}

    public func prompt(for item: String) -> String {
        promptTemplate.contains("{item}")
            ? promptTemplate.replacingOccurrences(of: "{item}", with: item)
            : promptTemplate + "\n\n" + item
    }

    /// Opens a new chat (in `project`, if given) with the prompt typed in, not sent.
    public func ask(_ item: String, service: String, project: AskProject?) {
        deliver?(.chatPrompt(prompt(for: item), service: service, url: project?.url))
    }
}

/// Menu entries for asking about `item`; use inside an existing `.contextMenu`.
public struct AskMenuItems: View {
    private let item: () -> String
    private let ai = AskAI.shared

    public init(_ item: @escaping () -> String) {
        self.item = item
    }

    public var body: some View {
        ForEach(ai.services) { service in
            if service.projects.isEmpty {
                Button("Ask \(service.name)") { ai.ask(item(), service: service.id, project: nil) }
            } else {
                Menu("Ask \(service.name)") {
                    if let preferred = service.defaultProject {
                        Button("\(preferred.name) (default)") { ai.ask(item(), service: service.id, project: preferred) }
                        Divider()
                    }
                    ForEach(service.projects.filter { $0.url != service.defaultProjectURL }) { project in
                        Button(project.name) { ai.ask(item(), service: service.id, project: project) }
                    }
                    Divider()
                    Button("No project") { ai.ask(item(), service: service.id, project: nil) }
                }
            }
        }
    }
}

public extension View {
    /// Adds an "Ask ChatGPT / Claude / Muse" right-click menu about this view's content.
    /// `item` describes the thing in plain text and is only evaluated when the menu is used.
    func askable(_ item: @escaping () -> String) -> some View {
        contextMenu { AskMenuItems(item) }
    }
}
