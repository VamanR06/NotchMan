import SwiftUI

/// Something an app wants surfaced outside itself (the Today app shows these): a meeting, a task due, a job
/// deadline, an agent that needs you, a pending approval.
public struct BoardItem: Identifiable {
    /// `agent`: a session that needs you; `session`: one working or just finished.
    public enum Kind: Sendable { case event, task, deadline, agent, approval, session }

    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var date: Date?
    public var isAllDay: Bool
    public var tint: Color
    /// Something is in progress (a working session): shown with a spinner.
    public var isWorking: Bool
    /// Runs in place (check off, Allow, Join) without leaving the app showing the item.
    public var primary: BoardAction?
    public var secondary: BoardAction?
    /// Opens the item in its own app.
    public var open: BoardAction?

    public init(id: String, kind: Kind, title: String, subtitle: String? = nil, date: Date? = nil,
                isAllDay: Bool = false, tint: Color = .white, isWorking: Bool = false, primary: BoardAction? = nil,
                secondary: BoardAction? = nil, open: BoardAction? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.date = date
        self.isAllDay = isAllDay
        self.tint = tint
        self.isWorking = isWorking
        self.primary = primary
        self.secondary = secondary
        self.open = open
    }
}

public struct BoardAction {
    public var label: String
    public var systemImage: String
    public var perform: @MainActor () -> Void

    public init(_ label: String, systemImage: String, perform: @escaping @MainActor () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.perform = perform
    }
}

/// A folder an active Claude Code session is working in (published by the Agents app).
public struct BoardProject: Identifiable, Hashable, Sendable {
    public var id: String { cwd }
    public var name: String
    public var cwd: String
    /// Background agent short id, when it is one (lets text be typed into its notch terminal).
    public var agentID: String?

    public init(name: String, cwd: String, agentID: String? = nil) {
        self.name = name
        self.cwd = cwd
        self.agentID = agentID
    }

    public var folderName: String { (cwd as NSString).lastPathComponent }
}

/// Shared, read-mostly state apps publish for each other. Apps don't import each other, and messages always
/// act; the board is how one app (Today, Shelf) can show what others know.
@MainActor @Observable
public final class NotchBoard {
    public static let shared = NotchBoard()

    private var itemsByApp: [String: [BoardItem]] = [:]
    public private(set) var projects: [BoardProject] = []

    /// Set by the Agents app: types `text` into that project's open notch terminal, without Return. Returns
    /// false when no terminal is open for it.
    @ObservationIgnored public var insertIntoSession: ((BoardProject, String) -> Bool)?

    public init() {}

    public func publish(_ items: [BoardItem], from appID: String) {
        itemsByApp[appID] = items
    }

    public func publishProjects(_ projects: [BoardProject]) {
        if projects != self.projects { self.projects = projects }
    }

    public var allItems: [BoardItem] {
        itemsByApp.keys.sorted().flatMap { itemsByApp[$0] ?? [] }
    }

    public func items(_ kind: BoardItem.Kind) -> [BoardItem] {
        allItems.filter { $0.kind == kind }
    }
}
