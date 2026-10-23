import NotchKit
import SwiftUI

struct CalendarExpandedView: View {
    let app: CalendarApp

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            DaySummary(app: app)
                .frame(width: 120, alignment: .leading)

            Rectangle().fill(.white.opacity(0.1)).frame(width: 1)

            if !app.isConnected {
                ConnectPrompt(openSettings: app.openSettings)
            } else if app.items.isEmpty {
                VStack(spacing: 6) {
                    Text(app.isLoading ? "Loading…" : "Nothing coming up this week")
                        .foregroundStyle(.white.opacity(0.6))
                    errorText
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 6) {
                    if let meeting = app.headsUp {
                        HeadsUpBanner(app: app, item: meeting)
                    }
                    Timeline(app: app)
                }
            }
        }
        .task { await app.refreshIfStale() }
    }

    @ViewBuilder
    private var errorText: some View {
        if let error = app.errors.first {
            Text(error).font(.system(size: 10)).foregroundStyle(.red.opacity(0.8)).lineLimit(2)
        }
    }
}

private struct DaySummary: View {
    let app: CalendarApp

    var body: some View {
        let today = app.items.filter { Calendar.current.isDateInToday($0.start) }
        VStack(alignment: .leading, spacing: 2) {
            Text(app.now, format: .dateTime.weekday(.wide))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
            Text(app.now, format: .dateTime.day())
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
            Text(app.now, format: .dateTime.month(.wide))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 6)
            if app.isConnected {
                Text(today.isEmpty ? "No events today" : "\(today.count) today")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                HStack(spacing: 6) {
                    Button { Task { await app.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(app.isLoading ? 360 : 0))
                            .animation(app.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                                       value: app.isLoading)
                    }
                    Button(action: NotionLinks.openNotionCalendar) {
                        Image(systemName: "calendar.badge.clock")
                    }
                    .help("Open Notion Calendar")
                    if !app.errors.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(app.errors.joined(separator: "\n"))
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The meeting about to start: live countdown, a big Join button, and any overlap.
private struct HeadsUpBanner: View {
    let app: CalendarApp
    let item: CalendarItem

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = item.start.timeIntervalSince(context.date)
                    Text(left > 0 ? String(format: "Starts in %d:%02d", Int(left) / 60, Int(left) % 60) : "Starting now")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.orange)
                }
                if let others = app.conflicts[item.id], let first = others.first {
                    Label("Overlaps with \(first.title)\(others.count > 1 ? " +\(others.count - 1)" : "")",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let meeting = item.meetingURL {
                Button {
                    NSWorkspace.shared.open(meeting)
                    app.dismissHeadsUp()
                } label: {
                    Label("Join", systemImage: "video.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(.green))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
            Button(action: app.dismissHeadsUp) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct ConnectPrompt: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("Connect Google Calendar to see your schedule.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Open Settings", action: openSettings)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Groups the timeline by day. Today always gets a section (possibly empty) so it's easy to find.
enum CalendarDays {
    enum Kind: Equatable { case today, tomorrow, later }

    static func kind(of day: Date, now: Date, calendar: Calendar = .current) -> Kind {
        if calendar.isDate(day, inSameDayAs: now) { return .today }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(day, inSameDayAs: tomorrow) {
            return .tomorrow
        }
        return .later
    }

    static func group(_ items: [CalendarItem], now: Date, calendar: Calendar = .current) -> [(day: Date, items: [CalendarItem])] {
        var grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.start) }
        let today = calendar.startOfDay(for: now)
        if grouped[today] == nil { grouped[today] = [] }
        return grouped.keys.sorted().map { ($0, grouped[$0]!) }
    }
}

private struct Timeline: View {
    let app: CalendarApp

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            TimelineSections(app: app, lazy: true)
        }
    }
}

/// The days and their events (lazy inside the scroll view; plain when rendered on its own, e.g. in tests).
struct TimelineSections: View {
    let app: CalendarApp
    var lazy = false

    var body: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) { sections }
        } else {
            VStack(alignment: .leading, spacing: 4) { sections }
        }
    }

    @ViewBuilder
    private var sections: some View {
        let days = CalendarDays.group(app.items, now: app.now)
                ForEach(Array(days.enumerated()), id: \.element.day) { index, entry in
                    let past = entry.items.filter { $0.isPast(at: app.now) }
                    let upcoming = entry.items.filter { !$0.isPast(at: app.now) }
                    let kind = CalendarDays.kind(of: entry.day, now: app.now)
                    Section {
                        if !past.isEmpty {
                            EarlierToggle(app: app, count: past.count)
                        }
                        ForEach(app.showPastEvents ? entry.items : upcoming) { item in
                            EventRow(app: app, item: item, now: app.now)
                                .notchSelected(item.id == app.selectedItem?.id)
                        }
                        if kind == .today && upcoming.isEmpty {
                            Text(past.isEmpty ? "Nothing scheduled today" : "Nothing else today")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                        }
                    } header: {
                        DayHeader(day: entry.day, kind: kind, count: entry.items.count, isFirst: index == 0)
                    }
                }
    }
}

/// A day's header: a colored pill for Today / Tomorrow (weekday name for later days), the date, a rule across,
/// and the event count.
private struct DayHeader: View {
    let day: Date
    let kind: CalendarDays.Kind
    let count: Int
    let isFirst: Bool

    var body: some View {
        HStack(spacing: 8) {
            label
            Text(day.formatted(kind == .later ? .dateTime.month(.abbreviated).day() : .dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            Rectangle()
                .fill(.white.opacity(kind == .today ? 0.25 : 0.12))
                .frame(height: 1)
            if count > 0 {
                Text("\(count) event\(count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.top, isFirst ? 2 : 12)
        .padding(.bottom, 4)
        .background(.black)
    }

    @ViewBuilder
    private var label: some View {
        switch kind {
        case .today:
            pill("TODAY", fill: .red, text: .white)
        case .tomorrow:
            pill("TOMORROW", fill: .orange.opacity(0.9), text: .black)
        case .later:
            Text(day.formatted(.dateTime.weekday(.wide)))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private func pill(_ title: String, fill: Color, text: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(text)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(fill))
    }
}

/// "3 earlier events ▸" — shows or hides today's finished events.
private struct EarlierToggle: View {
    @Bindable var app: CalendarApp
    let count: Int
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { app.showPastEvents.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(app.showPastEvents ? 90 : 0))
                Text(app.showPastEvents ? "Hide earlier events" : "\(count) earlier event\(count == 1 ? "" : "s")")
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(hovering ? 0.7 : 0.45))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct EventRow: View {
    let app: CalendarApp
    let item: CalendarItem
    let now: Date
    @State private var hovering = false
    @State private var editing = false

    var body: some View {
        VStack(spacing: 4) {
            row
            if editing {
                EventTimeEditor(app: app, item: item) { editing = false }
            }
        }
    }

    private var isPast: Bool { item.isPast(at: now) }

    private var row: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(item.color)
                .frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(timeText)
                    Text("·")
                    Text(item.calendarName).lineLimit(1)
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 4)
            if let others = app.conflicts[item.id] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
                    .help("Overlaps with " + others.map(\.title).joined(separator: ", "))
            }
            if item.isOngoing(at: now) {
                Text("NOW")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(.orange.opacity(0.85)))
                    .foregroundStyle(.black)
            }
            if let meeting = item.meetingURL {
                Button { NSWorkspace.shared.open(meeting) } label: {
                    Label("Join", systemImage: "video.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.green.opacity(0.8)))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hovering ? 0.08 : 0)))
        .opacity(isPast ? 0.45 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            if item.canEdit && item.eventID != nil {
                if app.canChangeEvents {
                    Menu("Reschedule") {
                        ForEach(EventMoveOption.options(for: item)) { option in
                            Button(option.title) { app.reschedule(item, to: option.newStart(for: item)) }
                        }
                        Divider()
                        Button(item.isAllDay ? "Pick Date…" : "Pick Date & Time…") { editing = true }
                    }
                } else {
                    Button("Allow Rescheduling…") { app.openSettings() }
                }
                Divider()
            }
            AskMenuItems { askText }
            Divider()
            Button("Open in Notion Calendar", action: NotionLinks.openNotionCalendar)
            if let url = item.url { Button("Open in Google Calendar") { NSWorkspace.shared.open(url) } }
            if let meeting = item.meetingURL { Button("Join Meeting") { NSWorkspace.shared.open(meeting) } }
        }
    }

    /// What "Ask ChatGPT/Claude/Muse" sends about this event.
    private var askText: String {
        var lines = ["Calendar event: \(item.title)",
                     "When: \(item.start.formatted(.dateTime.weekday(.wide).month().day())), \(timeText)",
                     "Calendar: \(item.calendarName)"]
        if let location = item.location, !location.isEmpty { lines.append("Location: \(location)") }
        if let meeting = item.meetingURL { lines.append("Meeting link: \(meeting.absoluteString)") }
        return lines.joined(separator: "\n")
    }

    private var timeText: String {
        if item.isAllDay { return "All day" }
        let start = item.start.formatted(date: .omitted, time: .shortened)
        guard let end = item.end else { return start }
        return "\(start) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    private func open() { app.open(item) }
}

/// Inline picker for a new start; the event keeps its length.
private struct EventTimeEditor: View {
    let app: CalendarApp
    let item: CalendarItem
    let done: () -> Void
    @State private var start: Date

    init(app: CalendarApp, item: CalendarItem, done: @escaping () -> Void) {
        self.app = app
        self.item = item
        self.done = done
        _start = State(initialValue: item.start)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            DatePicker("Start", selection: $start,
                       displayedComponents: item.isAllDay ? [.date] : [.date, .hourAndMinute])
                .datePickerStyle(.field)
                .labelsHidden()
                .fixedSize()
            if !item.isAllDay {
                Text("→ \(item.moved(to: start).end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button("Cancel", action: done)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
            Button {
                app.reschedule(item, to: start)
                done()
            } label: {
                Text("Move")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill(.white))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .disabled(start == item.start)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
        .onAppear { app.setEditing(true) }
        .onDisappear { app.setEditing(false) }
    }
}
