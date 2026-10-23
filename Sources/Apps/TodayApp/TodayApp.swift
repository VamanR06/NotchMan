import AppKit
import SwiftUI
import NotchKit

/// One glance at the day: quick add, the next meeting, what needs you, tasks due and job deadlines — gathered
/// from what the other apps publish to `NotchBoard`.
@MainActor @Observable
public final class TodayApp: NotchApp {
    public let id = "today"
    public let name = "Today"
    public let iconSystemName = "sun.max"
    public var expandedHeight: CGFloat { 250 }
    public var expandedWidth: CGFloat { 700 }

    /// Quick-add text and whether it becomes an event (else a task); nil follows what the text looks like.
    var quickText = ""
    var forceEvent: Bool?
    /// Bumped to put the cursor in the quick-add field (⌘N from anywhere in the notch).
    private(set) var focusRequest = 0
    let selection = NotchListSelection()

    @ObservationIgnored private var context: NotchContext?
    private let board = NotchBoard.shared

    public init() {}

    public func activate(context: NotchContext) {
        self.context = context
    }

    // MARK: - Sections

    struct Section: Identifiable {
        let id: String
        let title: String
        let items: [BoardItem]
        /// Rows shown before "+N more".
        let limit: Int
    }

    /// Sections the user opened past their limit.
    var expandedSections: Set<String> = []

    /// Left: what's happening (meetings, what needs you, sessions). Right: what's due.
    var columns: (left: [Section], right: [Section]) {
        let now = Date()
        let events = board.items(.event).sorted { ($0.date ?? now) < ($1.date ?? now) }
        let needsYou = board.items(.approval) + board.items(.agent)
        let sessions = board.items(.session).sorted { $0.isWorking && !$1.isWorking }
        let tasks = board.items(.task).sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        let deadlines = board.items(.deadline).sorted { ($0.date ?? now) < ($1.date ?? now) }
        let left = [
            Section(id: "events", title: "Next up", items: events, limit: 3),
            Section(id: "needs", title: "Needs you", items: needsYou, limit: 3),
            Section(id: "sessions", title: "Sessions", items: sessions, limit: 4),
        ]
        let right = [
            Section(id: "tasks", title: "Due", items: tasks, limit: 6),
            Section(id: "deadlines", title: "Deadlines", items: deadlines, limit: 3),
        ]
        return (left.filter { !$0.items.isEmpty }, right.filter { !$0.items.isEmpty })
    }

    var sections: [Section] { columns.left + columns.right }

    func visibleItems(_ section: Section) -> [BoardItem] {
        expandedSections.contains(section.id) ? section.items : Array(section.items.prefix(section.limit))
    }

    func toggleExpanded(_ section: Section) {
        if expandedSections.contains(section.id) { expandedSections.remove(section.id) } else { expandedSections.insert(section.id) }
    }

    /// Items in display order (left column, then right), for keyboard selection.
    var displayedItems: [BoardItem] { sections.flatMap(visibleItems) }

    var selectedItemID: String? {
        let shown = displayedItems
        return selection.index.flatMap { shown.indices.contains($0) ? shown[$0].id : nil }
    }

    // MARK: - Quick add

    var parsed: QuickAdd { QuickAddParser.parse(quickText) }

    var addsEvent: Bool { forceEvent ?? parsed.looksLikeEvent }

    /// An event needs a date; a task just needs a title.
    var canAdd: Bool {
        let item = parsed
        return !item.title.isEmpty && (!addsEvent || item.date != nil)
    }

    func submit() {
        guard canAdd else { return }
        let item = parsed
        let event = addsEvent
        context?.send(.quickAdd(item, asEvent: event), to: event ? "calendar" : "tasks", reveal: false)
        quickText = ""
        forceEvent = nil
    }

    func setTyping(_ typing: Bool) {
        context?.holdOpen(typing)
    }

    // MARK: - NotchApp

    public func receive(_ message: NotchMessage) {
        if message.name == NotchMessage.focusQuickAddName { focusRequest += 1 }
    }

    /// ↑/↓ select, Return runs the item's main action (Join, Done, Allow), ⌘Return opens it in its app, ⌘N types.
    public func handleKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "n" {
            focusRequest += 1
            return true
        }
        let shown = displayedItems
        return selection.handle(event, count: shown.count, open: { index in
            let item = shown[index]
            (item.primary ?? item.open)?.perform()
        }, secondary: { index in shown[index].open?.perform() })
    }

    public var dockBadge: NotchBadge? {
        board.items(.approval).isEmpty && board.items(.agent).isEmpty ? nil : .dot(.orange)
    }

    public func makeExpandedView() -> AnyView {
        AnyView(TodayView(app: self))
    }
}
