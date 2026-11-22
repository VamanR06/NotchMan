import Foundation

/// Something the command bar can find and open: a shelved file, a folder, an agent, a task.
public struct CommandItem: Identifiable {
    public let id: String
    public var title: String
    public var subtitle: String?
    /// SF Symbol.
    public var symbol: String
    /// What it is, shown beside it: "File", "Folder", "Agent", "Task".
    public var kind: String
    /// Other words it should be found by.
    public var keywords: [String]
    /// The app to show while it opens (an agent's session opens in the notch); nil closes the notch.
    public var revealsApp: String?
    public var run: @MainActor () -> Void

    public init(id: String, title: String, subtitle: String? = nil, symbol: String, kind: String, keywords: [String] = [],
                revealsApp: String? = nil, run: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.kind = kind
        self.keywords = keywords
        self.revealsApp = revealsApp
        self.run = run
    }
}

/// One value an action's parameter can take, picked from what the app knows (Jev chooses among these; it can't make
/// one up).
public struct CommandChoice: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case file, folder, text }

    public let id: String
    /// Shown in the bar, and sent to Jev (redacted per `kind`).
    public var label: String
    /// A path for files and folders (sent as `~/…`, redacted).
    public var path: String?
    public var kind: Kind

    public init(id: String, label: String, path: String? = nil, kind: Kind = .text) {
        self.id = id
        self.label = label
        self.path = path
        self.kind = kind
    }
}

public struct CommandParameter: Sendable {
    public var name: String
    /// What it is, for Jev: "the file to move".
    public var description: String
    public var choices: [CommandChoice]

    public init(name: String, description: String, choices: [CommandChoice]) {
        self.name = name
        self.description = description
        self.choices = choices
    }
}

/// Something the command bar can do when you describe it: "move the pdf I downloaded to resumes".
public struct CommandAction: Identifiable {
    public enum Risk: Sendable {
        /// Runs on Return (open, show, search).
        case safe
        /// Asks for a second Return first (move, approve, check off).
        case confirm
    }

    /// Stable name, e.g. `put_file`.
    public let id: String
    /// What it does, for Jev: "Put a file into a folder".
    public var description: String
    public var risk: Risk
    public var symbol: String
    public var parameters: [CommandParameter]
    /// One line for the bar: "Move Resume.pdf to Resumes".
    public var summary: @MainActor ([String: CommandChoice]) -> String
    public var perform: @MainActor ([String: CommandChoice]) -> Void
    public var revealsApp: String?

    public init(id: String, description: String, risk: Risk, symbol: String, parameters: [CommandParameter],
                revealsApp: String? = nil, summary: @escaping @MainActor ([String: CommandChoice]) -> String,
                perform: @escaping @MainActor ([String: CommandChoice]) -> Void) {
        self.id = id
        self.description = description
        self.risk = risk
        self.symbol = symbol
        self.parameters = parameters
        self.revealsApp = revealsApp
        self.summary = summary
        self.perform = perform
    }
}

/// What an app offers the command bar for what's typed so far.
public struct NotchCommands {
    public var items: [CommandItem]
    public var actions: [CommandAction]

    public init(items: [CommandItem] = [], actions: [CommandAction] = []) {
        self.items = items
        self.actions = actions
    }

    public static var none: NotchCommands { NotchCommands() }
}
