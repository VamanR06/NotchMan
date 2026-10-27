import SwiftUI
import NotchKit

/// Timeline of upcoming Google Calendar events.
@MainActor @Observable
public final class CalendarApp: NotchApp {
    public let id = "calendar"
    public let name = "Calendar"
    public let iconSystemName = "calendar"
    public var expandedHeight: CGFloat { editingEventID == nil ? 190 : 270 }

    private(set) var items: [CalendarItem] = []
    private(set) var errors: [String] = []
    private(set) var isLoading = false
    private(set) var lastRefresh: Date?
    /// Show today's finished events (otherwise they're folded into one "earlier" row).
    var showPastEvents = false {
        didSet { context?.defaults.set(showPastEvents, forKey: "showPastEvents") }
    }
    /// Ticks every 30s so relative times and the activity stay current.
    private(set) var now = Date()

    @ObservationIgnored private(set) var google: GoogleCalendarSource!
    @ObservationIgnored private var context: NotchContext?
    @ObservationIgnored private var timers: [Task<Void, Never>] = []
    @ObservationIgnored private var alertedEventIDs: Set<String> = []
    /// The meeting about to start, shown as a banner with a countdown and Join until shortly after it starts.
    private(set) var headsUp: CalendarItem?
    @ObservationIgnored private var dismissedHeadsUpIDs: Set<String> = []
    /// Overlapping events, by event id.
    private(set) var conflicts: [String: [CalendarItem]] = [:]
    /// How long before a meeting the notch opens with the heads-up (0 = off).
    var headsUpLead: Double = 90 {
        didSet { context?.defaults.set(headsUpLead, forKey: "headsUpLead") }
    }
    @ObservationIgnored private var refreshQueued = false

    /// How far ahead the timeline looks.
    private let horizonDays = 7

    public init() {}

    public func activate(context: NotchContext) {
        self.context = context
        google = GoogleCalendarSource(keychain: context.keychain, defaults: context.defaults)
        showPastEvents = context.defaults.bool(forKey: "showPastEvents")
        headsUpLead = context.defaults.object(forKey: "headsUpLead") as? Double ?? 90

        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        })
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                // Every 5s while a meeting is close, so the heads-up lands on time; else every 30s.
                try? await Task.sleep(for: .seconds(self?.tickInterval ?? 30))
                self?.tick()
            }
        })
    }

    public func deactivate() {
        timers.forEach { $0.cancel() }
        timers.removeAll()
    }

    var isConnected: Bool {
        google.isSignedIn
    }

    func refresh() async {
        // A refresh requested mid-flight (e.g. after changing settings) runs again once this one ends.
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

        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: horizonDays, to: start)!
        do {
            let collected = try await google.items(from: start, to: end)
            items = collected.sorted { ($0.start, $0.isAllDay ? 0 : 1) < ($1.start, $1.isAllDay ? 0 : 1) }
            conflicts = Conflicts.find(items)
            notifyTomorrowConflicts()
            errors = []
            lastRefresh = Date()
        } catch {
            // Offline or a Google hiccup: keep showing the last good list (and retry on the next open).
            errors = [error.localizedDescription]
            context?.logger.error("Google refresh failed: \(error.localizedDescription, privacy: .public)")
        }
        tick()
    }

    /// Refreshes on expand, but not more than once a minute.
    func refreshIfStale() async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        await refresh()
    }

    private var tickInterval: Double {
        let soon = items.contains { !$0.isAllDay && $0.start > now && $0.start.timeIntervalSince(now) < max(headsUpLead, 60) + 90 }
        return soon || headsUp != nil ? 5 : 30
    }

    private func tick() {
        now = Date()
        publishBoard()
        // The heads-up ends a minute after the meeting starts.
        if let current = headsUp, now.timeIntervalSince(current.start) > 60 { headsUp = nil }
        guard headsUpLead > 0 else { return }
        // Pop the notch open once per meeting, `headsUpLead` before it starts.
        if let next = upcomingTimedEvent, !alertedEventIDs.contains(next.id) {
            let until = next.start.timeIntervalSince(now)
            if until > 0, until <= headsUpLead {
                alertedEventIDs.insert(next.id)
                if !dismissedHeadsUpIDs.contains(next.id) { headsUp = next }
                context?.requestAttention(.expand(duration: until + 30))
            }
        }
    }

    /// The next timed event that hasn't started (declined ones don't count).
    private var upcomingTimedEvent: CalendarItem? {
        items.first { !$0.isAllDay && !$0.declined && $0.start > now }
    }

    func dismissHeadsUp() {
        if let headsUp { dismissedHeadsUpIDs.insert(headsUp.id) }
        withAnimation { headsUp = nil }
    }

    /// Once a day, a notification if tomorrow has double-bookings.
    private func notifyTomorrowConflicts() {
        guard let context, let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) else { return }
        let day = DateParsing.dayString(tomorrow)
        guard context.defaults.string(forKey: "conflictsNotifiedFor") != day else { return }
        let clashing = items.filter { conflicts[$0.id] != nil && Calendar.current.isDate($0.start, inSameDayAs: tomorrow) }
        guard !clashing.isEmpty else { return }
        context.defaults.set(day, forKey: "conflictsNotifiedFor")
        let names = clashing.prefix(3).map(\.title).joined(separator: ", ")
        context.notify(title: "Double-booked tomorrow", body: names)
    }

    /// The ongoing or next timed event within the next hour.
    var nextEvent: CalendarItem? {
        items.first { item in
            guard !item.isAllDay else { return false }
            if item.isOngoing(at: now) { return true }
            let until = item.start.timeIntervalSince(now)
            return until >= 0 && until <= 3600
        }
    }

    /// Chip: calendar icon in the event's color, then "now" or the minutes until it starts.
    public var activity: NotchActivity? {
        guard let event = nextEvent else { return nil }
        let ongoing = event.isOngoing(at: now)
        let minutes = Int(ceil(event.start.timeIntervalSince(now) / 60))
        let soon = ongoing || minutes <= 10
        let start = event.start
        return NotchActivity(priority: soon ? 20 : 5) {
            // The last two minutes count down by the second.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = start.timeIntervalSince(context.date)
                let text = ongoing || left <= 0 ? "now"
                    : left <= 120 ? String(format: "%d:%02d", Int(left) / 60, Int(left) % 60)
                    : "\(minutes)m"
                NotchChip(text, tint: soon ? .orange : .white) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(event.color)
                }
            }
        }
    }

    // MARK: - Board

    /// Today's remaining events, for the Today app.
    private func publishBoard() {
        let today = items.filter { Calendar.current.isDateInToday($0.start) && !$0.isPast(at: now) && !$0.declined }
        NotchBoard.shared.publish(today.map { item in
            BoardItem(id: item.id, kind: .event, title: item.title,
                      subtitle: conflicts[item.id] != nil ? "⚠ \(item.calendarName)" : item.calendarName,
                      date: item.start, isAllDay: item.isAllDay, tint: item.color,
                      primary: item.meetingURL.map { url in
                          BoardAction("Join", systemImage: "video.fill") { NSWorkspace.shared.open(url) }
                      },
                      open: BoardAction("Open", systemImage: "arrow.up.right") { [weak self] in self?.open(item) })
        }, from: id)
    }

    // MARK: - Quick add

    /// Creates the event a quick-add line described: 30 minutes unless it said "for …"; a bare day is all-day.
    func addEvent(_ item: QuickAdd) async {
        guard let start = item.date else { return }
        guard let calendar = google.defaultCalendarForNewEvents else {
            context?.showTransient(NotchTransient(id: "quickadd", systemImage: "exclamationmark.triangle.fill",
                                                  text: "No calendar", tint: .orange, duration: 2.5))
            return
        }
        let allDay = !item.hasTime
        let end = allDay
            ? Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
            : start.addingTimeInterval(item.duration ?? 30 * 60)
        do {
            try await google.insert(summary: item.title, calendarID: calendar.id, start: start, end: end, allDay: allDay)
            context?.showTransient(NotchTransient(id: "quickadd", systemImage: "calendar.badge.plus", text: "Added", tint: .green))
            await refresh()
        } catch {
            errors = [error.localizedDescription]
            context?.showTransient(NotchTransient(id: "quickadd", systemImage: "exclamationmark.triangle.fill",
                                                  text: "Not added", tint: .orange, duration: 2.5))
        }
    }

    public func receive(_ message: NotchMessage) {
        guard message.name == NotchMessage.quickAddEventName, let item = message.quickAdd else { return }
        Task { await addEvent(item) }
    }

    // MARK: - Keyboard

    let selection = NotchListSelection()

    /// Events in the order the timeline shows them.
    var displayedItems: [CalendarItem] {
        CalendarDays.group(items, now: now).flatMap { entry in
            showPastEvents ? entry.items : entry.items.filter { !$0.isPast(at: now) }
        }
    }

    var selectedItem: CalendarItem? {
        let shown = displayedItems
        return selection.index.flatMap { shown.indices.contains($0) ? shown[$0] : nil }
    }

    /// ↑/↓ select, Return opens the event, ⌘Return joins its meeting.
    public func handleKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "n" {
            context?.send(NotchMessage(name: NotchMessage.focusQuickAddName), to: "today")
            return true
        }
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty, event.charactersIgnoringModifiers == "e",
           let item = selectedItem, canEdit(item) {
            editingEventID = item.id
            return true
        }
        let shown = displayedItems
        return selection.handle(event, count: shown.count, open: { self.open(shown[$0]) }, secondary: { index in
            if let meeting = shown[index].meetingURL { NSWorkspace.shared.open(meeting) }
        })
    }

    /// Opens in Notion Calendar if installed, else Google Calendar on the web.
    func open(_ item: CalendarItem) {
        if NotionLinks.hasNotionCalendar {
            NotionLinks.openNotionCalendar()
        } else if let url = item.url {
            NSWorkspace.shared.open(url)
        }
    }

    func openSettings() {
        context?.openSettings()
    }

    /// For tests.
    func useItemsForTesting(_ items: [CalendarItem], now: Date) {
        self.items = items
        self.now = now
    }

    // MARK: - Rescheduling

    /// Google granted permission to change events (sign-ins from before rescheduling are read-only).
    var canChangeEvents: Bool { google.canEditEvents }

    /// Moves an event to `newStart`, keeping its length. The timeline updates right away and reverts if Google
    /// refuses.
    // MARK: - Editing

    /// The event whose editor is open (pencil, Edit…, or E on the selected event).
    var editingEventID: String?

    /// Events on calendars you can change, once Google allows changing events.
    func canEdit(_ item: CalendarItem) -> Bool {
        item.canEdit && item.eventID != nil && canChangeEvents
    }

    /// Saves an edited event: shown at once, written to Google, put back if that fails.
    func edit(_ item: CalendarItem, _ edit: GoogleCalendarSource.EventEdit) {
        guard let calendarID = item.calendarID, let eventID = item.eventID,
              let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let before = items[index]
        let timeChanged = edit.start != item.start || edit.end != item.end || edit.allDay != item.isAllDay
        withAnimation(.easeOut(duration: 0.2)) {
            items[index].title = edit.title
            items[index].start = edit.start
            items[index].end = edit.end
            items[index].isAllDay = edit.allDay
            items[index].location = edit.location.isEmpty ? nil : edit.location
            items[index].notes = edit.notes.isEmpty ? nil : edit.notes
            items.sort { ($0.start, $0.isAllDay ? 0 : 1) < ($1.start, $1.isAllDay ? 0 : 1) }
        }
        editingEventID = nil
        Task {
            do {
                try await google.update(calendarID: calendarID, eventID: eventID, edit: edit, timeChanged: timeChanged)
                errors = []
                await refresh()
            } catch {
                if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = before }
                items.sort { ($0.start, $0.isAllDay ? 0 : 1) < ($1.start, $1.isAllDay ? 0 : 1) }
                errors = [error.localizedDescription]
            }
        }
    }

    func reschedule(_ item: CalendarItem, to newStart: Date) {
        guard let calendarID = item.calendarID, let eventID = item.eventID,
              let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let (start, end) = item.moved(to: newStart)
        let before = items[index]
        withAnimation(.easeOut(duration: 0.2)) {
            items[index].start = start
            items[index].end = end
            items.sort { ($0.start, $0.isAllDay ? 0 : 1) < ($1.start, $1.isAllDay ? 0 : 1) }
        }
        Task {
            do {
                try await google.move(calendarID: calendarID, eventID: eventID, start: start, end: end, allDay: item.isAllDay)
                errors = []
                await refresh()
            } catch {
                if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = before }
                items.sort { ($0.start, $0.isAllDay ? 0 : 1) < ($1.start, $1.isAllDay ? 0 : 1) }
                errors = [error.localizedDescription]
            }
        }
    }

    /// Keep the notch open while a date picker is being used.
    func setEditing(_ editing: Bool) {
        context?.holdOpen(editing)
    }

    public func makeExpandedView() -> AnyView {
        AnyView(CalendarExpandedView(app: self))
    }

    public func makeSettingsView() -> AnyView? {
        AnyView(CalendarSettingsView(app: self, google: google))
    }
}
