import SwiftUI
import NotchKit

/// Unified timeline of Google Calendar events and dated Notion pages.
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
    /// Ticks every 30s so relative times and the activity stay current.
    private(set) var now = Date()

    @ObservationIgnored private(set) var google: GoogleCalendarSource!
    @ObservationIgnored private(set) var notion: NotionSource!
    @ObservationIgnored private var context: NotchContext?
    @ObservationIgnored private var timers: [Task<Void, Never>] = []
    @ObservationIgnored private var alertedEventIDs: Set<String> = []

    /// How far ahead the timeline looks.
    private let horizonDays = 7

    public init() {}

    public func activate(context: NotchContext) {
        self.context = context
        google = GoogleCalendarSource(keychain: context.keychain, defaults: context.defaults)
        notion = NotionSource(keychain: context.keychain, defaults: context.defaults)

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
        google.isSignedIn || (notion.hasToken && !notion.selection.isEmpty)
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: horizonDays, to: start)!
        var collected: [CalendarItem] = []
        var errors: [String] = []

        do { collected += try await google.items(from: start, to: end) } catch {
            errors.append(error.localizedDescription)
            context?.logger.error("Google refresh failed: \(error.localizedDescription)")
        }
        do { collected += try await notion.items(from: start, to: end) } catch {
            errors.append(error.localizedDescription)
            context?.logger.error("Notion refresh failed: \(error.localizedDescription)")
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

    public var activity: NotchActivity? {
        guard let event = nextEvent else { return nil }
        let ongoing = event.isOngoing(at: now)
        let minutes = Int(ceil(event.start.timeIntervalSince(now) / 60))
        let soon = ongoing || minutes <= 10
        return NotchActivity(priority: soon ? 20 : 5) {
            HStack(spacing: 5) {
                Circle().fill(event.color).frame(width: 6, height: 6)
                Text(event.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
        } trailing: {
            Text(ongoing ? "now" : "in \(minutes)m")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(soon ? .orange : .white.opacity(0.7))
        }
    }

    func openSettings() {
        context?.openSettings()
    }

    public func makeExpandedView() -> AnyView {
        AnyView(CalendarExpandedView(app: self))
    }

    public func makeSettingsView() -> AnyView? {
        AnyView(CalendarSettingsView(app: self, google: google, notion: notion))
    }
}
