import NotchKit
import SwiftUI

/// Two columns so the day fits without scrolling: what's happening on the left (next meeting, what needs you,
/// sessions), what's due on the right. One line per item; long lists fold behind "+N more".
struct TodayView: View {
    let app: TodayApp

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            QuickAddField(app: app)
            let columns = app.columns
            if columns.left.isEmpty && columns.right.isEmpty {
                Text("All clear — nothing due and no meetings left today.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    column(columns.left, empty: "No meetings or sessions right now.")
                    Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                    column(columns.right, empty: "Nothing due today.")
                }
            }
        }
    }

    private func column(_ sections: [TodayApp.Section], empty: String) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                if sections.isEmpty {
                    Text(empty)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 4)
                }
                ForEach(sections) { section in
                    SectionView(app: app, section: section)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct SectionView: View {
    let app: TodayApp
    let section: TodayApp.Section

    var body: some View {
        let visible = app.visibleItems(section)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(section.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(section.id == "needs" ? .orange : .white.opacity(0.45))
                    .textCase(.uppercase)
                Text("\(section.items.count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
                if section.items.count > section.limit {
                    Button(app.expandedSections.contains(section.id) ? "Less" : "+\(section.items.count - section.limit) more") {
                        withAnimation(.easeOut(duration: 0.15)) { app.toggleExpanded(section) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                }
            }
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                if section.id == "events" && index == 0 {
                    NextMeetingCard(item: item).notchSelected(item.id == app.selectedItemID)
                } else {
                    CompactRow(item: item).notchSelected(item.id == app.selectedItemID)
                }
            }
        }
    }
}

/// The next meeting, a little bigger: title, when, and Join.
private struct NextMeetingCard: View {
    let item: BoardItem

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(item.tint).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(TodayFormat.meetingWhen(item, now: context.date))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 4)
            if let join = item.primary {
                Button { join.perform() } label: {
                    Label(join.label, systemImage: join.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(.green))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
        .contentShape(Rectangle())
        .onTapGesture { item.open?.perform() }
    }
}

/// One line: mark, title, project or list in grey, time on the right, and a small action.
private struct CompactRow: View {
    let item: BoardItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            mark.frame(width: 14)
            HStack(spacing: 5) {
                Text(item.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(item.tint == .red ? .red.opacity(0.85) : .white.opacity(0.4))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let when = TodayFormat.when(item) {
                Text(when)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize()
            }
            if let secondary = item.secondary { ActionButton(action: secondary, tint: .white.opacity(0.15), dark: false) }
            if let primary = item.primary, item.kind != .task {
                ActionButton(action: primary, tint: item.kind == .approval ? item.tint : .white.opacity(0.15),
                             dark: item.kind == .approval)
            }
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { (item.open ?? item.primary)?.perform() }
    }

    /// Tasks get a check-off circle as their mark; sessions a spinner or ✓.
    @ViewBuilder
    private var mark: some View {
        switch item.kind {
        case .task:
            if let done = item.primary {
                Button { done.perform() } label: {
                    Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(item.tint.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Mark done")
            } else {
                Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(.white.opacity(0.3))
            }
        case .session:
            if item.isWorking {
                NotchSpinner(size: 10, lineWidth: 1.6)
            } else {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
            }
        case .event:
            Circle().fill(item.tint).frame(width: 6, height: 6)
        case .deadline:
            Image(systemName: "briefcase.fill").font(.system(size: 10)).foregroundStyle(item.tint)
        case .agent:
            Image(systemName: "exclamationmark.bubble.fill").font(.system(size: 11)).foregroundStyle(.orange)
        case .approval:
            Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(item.tint)
        }
    }
}

private struct ActionButton: View {
    let action: BoardAction
    let tint: Color
    let dark: Bool

    var body: some View {
        Button { action.perform() } label: {
            Text(action.label)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(tint))
                .foregroundStyle(dark ? .black : .white)
        }
        .buttonStyle(.plain)
    }
}

enum TodayFormat {
    /// "in 25m · 3:00 PM", "now · until 3:30 PM" style text for the next meeting.
    static func meetingWhen(_ item: BoardItem, now: Date) -> String {
        guard let start = item.date else { return item.subtitle ?? "" }
        if item.isAllDay { return "All day" }
        let time = start.formatted(date: .omitted, time: .shortened)
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        let lead: String
        if minutes <= 0 { lead = "now" } else if minutes < 60 { lead = "in \(minutes)m" } else {
            lead = "in \(minutes / 60)h\(minutes % 60 == 0 ? "" : " \(minutes % 60)m")"
        }
        return "\(lead) · \(time)" + (item.subtitle.map { " · \($0)" } ?? "")
    }

    /// The right-hand time for a row: a clock time today, a weekday otherwise; for sessions how long ago / since.
    static func when(_ item: BoardItem, now: Date = Date()) -> String? {
        guard let date = item.date else { return nil }
        if item.kind == .session {
            let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
            let span = minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
            return item.isWorking ? span : "\(span) ago"
        }
        if item.isAllDay { return Calendar.current.isDateInToday(date) ? "today" : date.formatted(.dateTime.weekday(.abbreviated)) }
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// "Call recruiter fri 3pm" → a preview of what it will make, and a Task/Event switch.
private struct QuickAddField: View {
    @Bindable var app: TodayApp
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.white.opacity(0.45))
            TextField("Quick add — “Call recruiter fri 3pm” or “buy milk tmrw #home”", text: $app.quickText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit(app.submit)
            if !app.quickText.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(preview)
                    .font(.system(size: 10))
                    .foregroundStyle(app.canAdd ? .white.opacity(0.5) : .orange)
                    .lineLimit(1)
                    .truncationMode(.head)
                Picker("", selection: Binding(get: { app.addsEvent }, set: { app.forceEvent = $0 })) {
                    Text("Task").tag(false)
                    Text("Event").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(focused ? 0.12 : 0.06)))
        .onChange(of: focused) { _, typing in app.setTyping(typing) }
        .onChange(of: app.focusRequest) { _, _ in
            NotchFocus.activateForTyping()
            focused = true
        }
    }

    /// What Return will create, kept short so it fits beside the field.
    private var preview: String {
        let item = app.parsed
        guard !item.title.isEmpty else { return "Add a title" }
        let format: Date.FormatStyle = item.hasTime
            ? .dateTime.weekday(.abbreviated).hour().minute()
            : .dateTime.weekday(.abbreviated).month(.abbreviated).day()
        if app.addsEvent {
            guard let date = item.date else { return "Events need a day and time" }
            let length = item.hasTime ? " · \(Int((item.duration ?? 1800) / 60))m" : " · all day"
            return "↵ \(date.formatted(format))\(length)"
        }
        return "↵ task" + (item.date.map { " due \($0.formatted(format))" } ?? "")
    }
}
