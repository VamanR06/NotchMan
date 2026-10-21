import SwiftUI
import NotchKit

/// Timeline of upcoming Google Calendar events.
@MainActor @Observable
public final class CalendarApp: NotchApp {
    public let id = "calendar"
    public let name = "Calendar"
    public let iconSystemName = "calendar"
    public var expandedHeight: CGFloat { 190 }

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
    @ObservationIgnored private var refreshQueued = false

    /// How far ahead the timeline looks.
    private let horizonDays = 7

    public init() {}

    public func activate(context: NotchContext) {
        self.context = context
        google = GoogleCalendarSource(keychain: context.keychain, defaults: context.defaults)
        showPastEvents = context.defaults.bool(forKey: "showPastEvents")

        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        })
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
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
        var collected: [CalendarItem] = []
        var errors: [String] = []

        do { collected += try await google.items(from: start, to: end) } catch {
            errors.append(error.localizedDescription)
            context?.logger.error("Google refresh failed: \(error.localizedDescription, privacy: .public)")
        }

        items = collected.sorted { ($0.start, $0.isAllDay ? 0 : 1) < ($1.start, $1.isAllDay ? 0 : 1) }
        self.errors = errors
        lastRefresh = Date()
        tick()
    }

    /// Refreshes on expand, but not more than once a minute.
    func refreshIfStale() async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        await refresh()
    }

    private func tick() {
        now = Date()
        // Pop the notch open once, a minute before each timed event.
        if let next = nextEvent, !alertedEventIDs.contains(next.id) {
            let until = next.start.timeIntervalSince(now)
            if until > 0, until <= 60 {
                alertedEventIDs.insert(next.id)
                context?.requestAttention(.expand(duration: 6))
            }
        }
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
        return NotchActivity(priority: soon ? 20 : 5) {
            NotchChip(ongoing ? "now" : "\(minutes)m", tint: soon ? .orange : .white) {
                Image(systemName: "calendar")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(event.color)
            }
        }
    }

    func openSettings() {
        context?.openSettings()
    }

    // MARK: - Rescheduling

    /// Google granted permission to change events (sign-ins from before rescheduling are read-only).
    var canChangeEvents: Bool { google.canEditEvents }

    /// Moves an event to `newStart`, keeping its length. The timeline updates right away and reverts if Google
    /// refuses.
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
