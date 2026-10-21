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
                Timeline(app: app)
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

private struct Timeline: View {
    let app: CalendarApp

    private var days: [(Date, [CalendarItem])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: app.items) { calendar.startOfDay(for: $0.start) }
        return grouped.keys.sorted().map { ($0, grouped[$0]!) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                ForEach(days, id: \.0) { day, items in
                    let past = items.filter { $0.isPast(at: app.now) }
                    Section {
                        if !past.isEmpty {
                            EarlierToggle(app: app, count: past.count)
                        }
                        ForEach(items.filter { app.showPastEvents || !$0.isPast(at: app.now) }) { item in
                            EventRow(app: app, item: item, now: app.now)
                        }
                    } header: {
                        Text(Self.dayLabel(day))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                            .textCase(.uppercase)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                            .background(.black)
                    }
                }
            }
        }
    }

    private static func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
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

    /// Opens in Notion Calendar if installed, else Google Calendar on the web.
    private func open() {
        if NotionLinks.hasNotionCalendar {
            NotionLinks.openNotionCalendar()
        } else if let url = item.url {
            NSWorkspace.shared.open(url)
        }
    }
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
