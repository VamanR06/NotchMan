import AppKit
import SwiftUI
import NotchKit

/// Open tasks from Notion databases (task boards), with check-off.
@MainActor @Observable
public final class TasksApp: NotchApp {
    public let id = "tasks"
    public let name = "Tasks"
    public let iconSystemName = "checklist"
    public var expandedHeight: CGFloat { 190 }

    private(set) var databases: [TaskDatabase] = []
    private(set) var tasks: [NotionTask] = [] {
        didSet { publishBoard() }
    }
    private(set) var isConnected = false
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var now = Date() {
        didSet { publishBoard() }
    }

    /// Per database: `enabled`, `due` (date property, "" for none) and `done` (property, "" for none).
    /// A missing `due`/`done` key means "auto-detect".
    var config: [String: [String: String]] {
        didSet { context?.defaults.set(config, forKey: "databases") }
    }

    @ObservationIgnored private var context: NotchContext?
    @ObservationIgnored private var client: NotionClient!
    @ObservationIgnored private var timers: [Task<Void, Never>] = []
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var refreshQueued = false

    public init() {
        config = [:]
    }

    public func activate(context: NotchContext) {
        self.context = context
        client = NotionClient(keychain: context.keychain)
        migrateFromCalendarApp(context)
        config = context.defaults.dictionary(forKey: "databases") as? [String: [String: String]] ?? [:]
        isConnected = client.hasToken

        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        })
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.now = Date()
            }
        })
    }

    public func deactivate() {
        timers.forEach { $0.cancel() }
        timers.removeAll()
    }

    /// Notion used to live in the Calendar app; carry its token and database choice over once.
    private func migrateFromCalendarApp(_ context: NotchContext) {
        let oldKeychain = Keychain(service: "com.notchman.app.calendar")
        guard !client.hasToken, let token = oldKeychain.string(for: "notion.token") else { return }
        client.setToken(token)
        oldKeychain.remove("notion.token")
        if let oldDefaults = UserDefaults(suiteName: "com.notchman.app.calendar"),
           let selection = oldDefaults.dictionary(forKey: "notion.selection") as? [String: String] {
            let migrated = selection.mapValues { ["enabled": "1", "due": $0] }
            context.defaults.set(migrated, forKey: "databases")
            oldDefaults.removeObject(forKey: "notion.selection")
        }
        context.logger.notice("Migrated Notion settings from the Calendar app")
    }

    // MARK: - Configuration

    func isEnabled(_ db: TaskDatabase) -> Bool { config[db.id]?["enabled"] == "1" }

    func setEnabled(_ db: TaskDatabase, _ enabled: Bool) {
        config[db.id, default: [:]]["enabled"] = enabled ? "1" : nil
        Task { await refresh() }
    }

    func dueProperty(for db: TaskDatabase) -> String? {
        switch config[db.id]?["due"] {
        case nil: db.dateProperties.first
        case "": nil
        case let name?: db.dateProperties.contains(name) ? name : db.dateProperties.first
        }
    }

    func setDueProperty(_ name: String?, for db: TaskDatabase) {
        config[db.id, default: [:]]["due"] = name ?? ""
        Task { await refresh() }
    }

    func doneRule(for db: TaskDatabase) -> DoneRule? {
        switch config[db.id]?["done"] {
        case nil: db.doneRules.first
        case "": nil
        case let name?: db.doneRules.first { $0.property == name } ?? db.doneRules.first
        }
    }

    func setDoneProperty(_ name: String?, for db: TaskDatabase) {
        config[db.id, default: [:]]["done"] = name ?? ""
        Task { await refresh() }
    }

    func connect(token: String) async {
        client.setToken(token)
        isConnected = client.hasToken
        await refresh()
    }

    func disconnect() {
        client.setToken(nil)
        isConnected = false
        databases = []
        tasks = []
        config = [:]
    }

    // MARK: - Loading

    func refresh() async {
        guard isConnected else { return }
        guard !isLoading else {
            refreshQueued = true
            return
        }
        isLoading = true
        defer {
            isLoading = false
            if refreshQueued {
                refreshQueued = false
                Task { await refresh() }
            }
        }

        do {
            databases = try await client.databases()
            var loaded: [NotionTask] = []
            for db in databases where isEnabled(db) {
                let rule = doneRule(for: db)
                context?.logger.notice("""
                    Loading \(db.title, privacy: .public): due=\(self.dueProperty(for: db) ?? "none", privacy: .public) \
                    done=\(rule?.label ?? "none", privacy: .public)
                    """)
                loaded += try await client.openTasks(in: db, dueProperty: dueProperty(for: db), doneRule: rule)
            }
            tasks = loaded.sorted(by: Self.order)
            error = nil
            context?.logger.notice("Loaded \(loaded.count, privacy: .public) open tasks")
        } catch {
            self.error = error.localizedDescription
            context?.logger.error("Tasks refresh failed: \(error.localizedDescription, privacy: .public)")
        }
        lastRefresh = Date()
        now = Date()
    }

    /// Refreshes on expand, but not more than once a minute.
    func refreshIfStale() async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        await refresh()
    }

    private static func order(_ a: NotionTask, _ b: NotionTask) -> Bool {
        switch (a.due, b.due) {
        case let (x?, y?): x == y ? a.title < b.title : x < y
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    // MARK: - Actions

    func canCheckOff(_ task: NotionTask) -> Bool {
        databases.first { $0.id == task.databaseID }.flatMap(doneRule(for:)) != nil
    }

    /// Optimistically toggles a task and writes it back to Notion; reverts on failure.
    func toggle(_ task: NotionTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }),
              let db = databases.first(where: { $0.id == task.databaseID }),
              let rule = doneRule(for: db) else { return }
        let done = !tasks[index].isDone
        withAnimation(.easeOut(duration: 0.15)) { tasks[index].isDone = done }
        Task {
            do {
                try await client.setDone(task, done: done, rule: rule)
                error = nil
            } catch {
                if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i].isDone = !done }
                self.error = error.localizedDescription
            }
        }
    }

    /// Whether the task's database has a due property to write.
    func canReschedule(_ task: NotionTask) -> Bool {
        databases.first { $0.id == task.databaseID }.flatMap(dueProperty(for:)) != nil
    }

    /// Moves (or clears, with nil) a task's due date in Notion; updates the list right away, reverts on failure.
    func reschedule(_ task: NotionTask, to date: Date?, allDay: Bool) {
        apply([DueChange(task: task, due: date, allDay: allDay)])
    }

    /// A new due date for one task.
    struct DueChange {
        let task: NotionTask
        let due: Date?
        let allDay: Bool
    }

    /// Moves tasks at once: the list updates right away, then each is written to Notion in turn (Notion allows
    /// about three requests a second); any that fail go back to their old date.
    func apply(_ changes: [DueChange]) {
        let writable = changes.compactMap { change -> (DueChange, String, NotionTask)? in
            guard let db = databases.first(where: { $0.id == change.task.databaseID }),
                  let property = dueProperty(for: db),
                  let before = tasks.first(where: { $0.id == change.task.id }) else { return nil }
            return (change, property, before)
        }
        guard !writable.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            for (change, _, _) in writable {
                guard let index = tasks.firstIndex(where: { $0.id == change.task.id }) else { continue }
                tasks[index].due = change.due
                tasks[index].dueIsAllDay = change.allDay
            }
            tasks.sort(by: Self.order)
        }
        Task {
            var failed: [String] = []
            var lastError: Error?
            for (change, property, before) in writable {
                do {
                    try await client.setDue(change.task, property: property, to: change.due, allDay: change.allDay)
                } catch {
                    lastError = error
                    failed.append(change.task.title)
                    if let i = tasks.firstIndex(where: { $0.id == change.task.id }) { tasks[i] = before }
                }
            }
            if failed.isEmpty {
                error = nil
            } else {
                tasks.sort(by: Self.order)
                let what = failed.count == 1 ? "“\(failed[0])”" : "\(failed.count) tasks"
                error = "Couldn't move \(what): \(lastError?.localizedDescription ?? "unknown error")"
            }
            if writable.count > 1 {
                let moved = writable.count - failed.count
                context?.showTransient(NotchTransient(
                    id: "tasks", systemImage: failed.isEmpty ? "calendar.badge.checkmark" : "exclamationmark.triangle.fill",
                    text: failed.isEmpty ? "Moved \(moved)" : "\(failed.count) failed", tint: failed.isEmpty ? .green : .orange))
            }
        }
    }

    // MARK: - Selecting several

    /// Tasks picked for a batch action (⌘-click, ⇧-click, a section's Select, ⌘A, ⇧↑/↓).
    private(set) var selectedIDs: Set<String> = []
    /// Where a ⇧-click range starts.
    @ObservationIgnored private var selectionAnchor: String?

    var isSelecting: Bool { !selectedIDs.isEmpty }

    var selectedTasks: [NotionTask] { displayedTasks.filter { selectedIDs.contains($0.id) } }

    func toggleSelection(_ task: NotionTask) {
        if selectedIDs.contains(task.id) { selectedIDs.remove(task.id) } else { selectedIDs.insert(task.id) }
        selectionAnchor = task.id
        holdForSelection()
    }

    /// Selects every task between the last one picked and `task`, in list order.
    func selectRange(to task: NotionTask) {
        let shown = displayedTasks
        guard let anchor = selectionAnchor, let from = shown.firstIndex(where: { $0.id == anchor }),
              let to = shown.firstIndex(where: { $0.id == task.id }) else {
            toggleSelection(task)
            return
        }
        for item in shown[min(from, to)...max(from, to)] { selectedIDs.insert(item.id) }
        holdForSelection()
    }

    func selectAll(in section: TaskSection? = nil) {
        let shown = displayedTasks.filter { section == nil || self.section(of: $0) == section }
        selectedIDs.formUnion(shown.map(\.id))
        selectionAnchor = shown.last?.id
        holdForSelection()
    }

    func clearSelection() {
        selectedIDs.removeAll()
        selectionAnchor = nil
        context?.holdOpen(false)
    }

    /// The notch stays open while picking tasks, so moving to the action bar doesn't close it.
    private func holdForSelection() {
        if selectedIDs.isEmpty { clearSelection() } else { context?.holdOpen(true) }
    }

    /// The selected tasks that can be rescheduled (their database has a due date property).
    var reschedulableSelection: [NotionTask] { selectedTasks.filter(canReschedule) }

    func rescheduleSelection(_ option: TaskDueOption) {
        apply(Self.changes(reschedulableSelection, option: option, now: Date()))
        clearSelection()
    }

    func rescheduleSelection(to date: Date, includeTime: Bool) {
        apply(Self.changes(reschedulableSelection, to: date, includeTime: includeTime))
        clearSelection()
    }

    /// Each task moved by `option`, as the single-task menu does: tasks with a time keep it, date-only tasks
    /// stay date-only, and "Push 1 Week" moves each from its own due date.
    static func changes(_ tasks: [NotionTask], option: TaskDueOption, now: Date) -> [DueChange] {
        tasks.map { DueChange(task: $0, due: option.target(for: $0, now: now), allDay: $0.due == nil || $0.dueIsAllDay) }
    }

    /// One date for all of them. Without `includeTime`, each keeps its own time of day (if it had one).
    static func changes(_ tasks: [NotionTask], to date: Date, includeTime: Bool) -> [DueChange] {
        tasks.map { task in
            if includeTime { return DueChange(task: task, due: date, allDay: false) }
            let keepsTime = task.due != nil && !task.dueIsAllDay
            return DueChange(task: task, due: Reschedule.day(date, keepingTimeOf: keepsTime ? task.due : nil), allDay: !keepsTime)
        }
    }

    /// For tests: a task list without Notion.
    func useTasksForTesting(_ tasks: [NotionTask], now: Date) {
        self.tasks = tasks
        self.now = now
    }

    func removeDueFromSelection() {
        apply(reschedulableSelection.map { DueChange(task: $0, due: nil, allDay: true) })
        clearSelection()
    }

    /// Keep the notch open while a date picker is being used.
    // MARK: - Board

    /// Overdue and today's open tasks, for the Today app; checking off works in place.
    private func publishBoard() {
        let due = tasks.filter { !$0.isDone && [.overdue, .today].contains(section(of: $0)) }
        NotchBoard.shared.publish(due.map { task in
            let overdue = section(of: task) == .overdue
            return BoardItem(id: "task:\(task.id)", kind: .task, title: task.title,
                             subtitle: overdue ? "Overdue" : task.databaseTitle,
                             date: task.due, isAllDay: task.dueIsAllDay, tint: overdue ? .red : .white,
                             primary: canCheckOff(task) ? BoardAction("Done", systemImage: "checkmark.circle") { [weak self] in
                                 self?.toggle(task)
                             } : nil,
                             open: BoardAction("Open", systemImage: "arrow.up.right") { [weak self] in self?.open(task) })
        }, from: id)
    }

    // MARK: - Quick add

    /// Database new tasks go to unless the text names another with `#tag`.
    var quickAddDatabaseID: String {
        get { context?.defaults.string(forKey: "quickAddDatabase") ?? "" }
        set { context?.defaults.set(newValue, forKey: "quickAddDatabase"); quickAddRevision += 1 }
    }
    private var quickAddRevision = 0

    var enabledDatabases: [TaskDatabase] { databases.filter(isEnabled) }

    /// Where a quick-add title goes: a `#tag` matching an enabled database's name (exact word, case-insensitive),
    /// else the chosen default, else the first enabled database. Returns the title with the tag removed.
    static func route(_ title: String, databases: [TaskDatabase], defaultID: String) -> (TaskDatabase, String)? {
        guard !databases.isEmpty else { return nil }
        var words = title.split(separator: " ").map(String.init)
        if let index = words.firstIndex(where: { $0.hasPrefix("#") && $0.count > 1 }) {
            let tag = words[index].dropFirst().lowercased()
            if let db = databases.first(where: { db in
                db.title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0 == tag }
            }) {
                words.remove(at: index)
                return (db, words.joined(separator: " "))
            }
        }
        let fallback = databases.first { $0.id == defaultID } ?? databases[0]
        return (fallback, title)
    }

    func addTask(title: String, due: Date?, allDay: Bool) async {
        _ = quickAddRevision
        guard let (db, title) = Self.route(title, databases: enabledDatabases, defaultID: quickAddDatabaseID) else {
            context?.showTransient(NotchTransient(id: "quickadd", systemImage: "exclamationmark.triangle.fill",
                                                  text: "No task list", tint: .orange, duration: 2.5))
            return
        }
        do {
            let property = dueProperty(for: db)
            if let task = try await client.createTask(in: db, title: title, dueProperty: property, due: due, allDay: allDay) {
                tasks = (tasks + [task]).sorted(by: Self.order)
            }
            context?.showTransient(NotchTransient(id: "quickadd", systemImage: "checklist", text: "Added", tint: .green))
        } catch {
            self.error = error.localizedDescription
            context?.showTransient(NotchTransient(id: "quickadd", systemImage: "exclamationmark.triangle.fill",
                                                  text: "Not added", tint: .orange, duration: 2.5))
        }
    }

    public func receive(_ message: NotchMessage) {
        guard message.name == NotchMessage.quickAddTaskName, let item = message.quickAdd else { return }
        Task { await addTask(title: item.title, due: item.date, allDay: !item.hasTime) }
    }

    // MARK: - Keyboard

    let selection = NotchListSelection()

    func section(of task: NotionTask) -> TaskSection {
        guard let due = task.due else { return .noDate }
        let startOfToday = Calendar.current.startOfDay(for: now)
        if task.dueIsAllDay ? due < startOfToday : due < now { return .overdue }
        if Calendar.current.isDateInToday(due) { return .today }
        return .upcoming
    }

    /// Tasks in the order the list shows them (by section).
    var displayedTasks: [NotionTask] {
        let grouped = Dictionary(grouping: tasks, by: section(of:))
        return TaskSection.allCases.flatMap { grouped[$0] ?? [] }
    }

    var selectedTask: NotionTask? {
        let shown = displayedTasks
        return selection.index.flatMap { shown.indices.contains($0) ? shown[$0] : nil }
    }

    /// ↑/↓ select, Return opens in Notion, Space or ⌘Return checks off. ⇧↑/↓ and ⌘A pick several; Esc lets go.
    public func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53, isSelecting {  // Esc: drop the selection before closing the notch
            clearSelection()
            return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
            selectAll()
            return true
        }
        if event.modifierFlags.contains(.shift), event.keyCode == 125 || event.keyCode == 126 {
            let shown = displayedTasks
            if let current = selectedTask { selectedIDs.insert(current.id) }
            selection.move(event.keyCode == 125 ? 1 : -1, count: shown.count)
            if let next = selectedTask {
                selectedIDs.insert(next.id)
                selectionAnchor = next.id
            }
            holdForSelection()
            return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "n" {
            context?.send(NotchMessage(name: NotchMessage.focusQuickAddName), to: "today")
            return true
        }
        let shown = displayedTasks
        if event.keyCode == 49, let task = selectedTask {  // Space
            if canCheckOff(task) { toggle(task) }
            return true
        }
        return selection.handle(event, count: shown.count, open: { self.open(shown[$0]) },
                                secondary: { if self.canCheckOff(shown[$0]) { self.toggle(shown[$0]) } })
    }

    func setEditing(_ editing: Bool) {
        context?.holdOpen(editing)
    }

    func open(_ task: NotionTask) {
        if let url = task.url { Self.openInNotion(url) }
    }

    /// Opens a Notion URL in the desktop app if installed, otherwise in the browser.
    static func openInNotion(_ url: URL) {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "notion.id") != nil,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "notion"
            if let appURL = components.url, NSWorkspace.shared.open(appURL) { return }
        }
        NSWorkspace.shared.open(url)
    }

    func openSettings() {
        context?.openSettings()
    }

    // MARK: - Summary

    var openTasks: [NotionTask] { tasks.filter { !$0.isDone } }

    var overdueCount: Int {
        let today = Calendar.current.startOfDay(for: now)
        return openTasks.filter { task in
            guard let due = task.due else { return false }
            return task.dueIsAllDay ? due < today : due < now
        }.count
    }

    var dueTodayCount: Int {
        openTasks.filter { $0.due.map(Calendar.current.isDateInToday) ?? false }.count - overdueTodayCount
    }

    /// Timed tasks earlier today count as overdue, not "today".
    private var overdueTodayCount: Int {
        openTasks.filter { task in
            guard let due = task.due, !task.dueIsAllDay else { return false }
            return Calendar.current.isDateInToday(due) && due < now
        }.count
    }

    /// Chip: "2 late" in red when anything is overdue, otherwise "3 today".
    public var activity: NotchActivity? {
        let overdue = overdueCount, today = dueTodayCount
        guard overdue + today > 0 else { return nil }
        return NotchActivity(priority: 3) {
            if overdue > 0 {
                NotchChip("\(overdue) late", systemImage: "checklist", tint: .red)
            } else {
                NotchChip("\(today) today", systemImage: "checklist")
            }
        }
    }

    public func makeExpandedView() -> AnyView {
        AnyView(TasksView(app: self))
    }

    public func makeSettingsView() -> AnyView? {
        AnyView(TasksSettingsView(app: self))
    }
}
