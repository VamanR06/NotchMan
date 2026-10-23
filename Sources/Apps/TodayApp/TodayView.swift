import NotchKit
import SwiftUI

struct TodayView: View {
    let app: TodayApp

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            QuickAddField(app: app)
            let sections = app.sections
            if sections.isEmpty {
                Text("Nothing needs you right now.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            SwiftUI.Section {
                                ForEach(section.items) { item in
                                    BoardRow(item: item).notchSelected(item.id == app.selectedItemID)
                                }
                            } header: {
                                Text("\(section.title) · \(section.items.count)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(section.id == "needs" ? .orange.opacity(0.9) : .white.opacity(0.5))
                                    .textCase(.uppercase)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 3)
                                    .background(.black)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// "Call recruiter fri 3pm" → a preview of what it will make, and a Task/Event switch.
private struct QuickAddField: View {
    @Bindable var app: TodayApp
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.white.opacity(0.5))
                TextField("Quick add — “Call recruiter fri 3pm” or “buy milk tmrw #home”", text: $app.quickText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onSubmit(app.submit)
                if !app.quickText.isEmpty {
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
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(focused ? 0.12 : 0.07)))

            if !app.quickText.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(preview)
                    .font(.system(size: 10))
                    .foregroundStyle(app.canAdd ? .white.opacity(0.55) : .orange)
                    .lineLimit(1)
                    .padding(.leading, 8)
            }
        }
        .onChange(of: focused) { _, typing in app.setTyping(typing) }
        .onChange(of: app.focusRequest) { _, _ in
            NotchFocus.activateForTyping()
            focused = true
        }
    }

    private var preview: String {
        let item = app.parsed
        guard !item.title.isEmpty else { return "Add a title" }
        if app.addsEvent {
            guard let date = item.date else { return "Events need a day and time, e.g. “fri 3pm”" }
            let minutes = Int((item.duration ?? 1800) / 60)
            let when = item.hasTime
                ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " · all day"
            return "↵ Event “\(item.title)” · \(when)\(item.hasTime ? " · \(minutes) min" : "")"
        }
        let due = item.date.map { date in
            item.hasTime
                ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return "↵ Task “\(item.title)”" + (due.map { " · due \($0)" } ?? "")
    }
}

private struct BoardRow: View {
    let item: BoardItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(item.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let when = whenText {
                Text(when)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
            if let secondary = item.secondary {
                actionButton(secondary, prominent: false)
            }
            if let primary = item.primary {
                actionButton(primary, prominent: true)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { item.open?.perform() }
    }

    private func actionButton(_ action: BoardAction, prominent: Bool) -> some View {
        Button { action.perform() } label: {
            Label(action.label, systemImage: action.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(prominent ? item.tint.opacity(0.85) : .white.opacity(0.12)))
                .foregroundStyle(prominent ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    private var icon: String {
        switch item.kind {
        case .event: "calendar"
        case .task: "circle"
        case .deadline: "briefcase.fill"
        case .agent: "exclamationmark.bubble.fill"
        case .approval: "hand.raised.fill"
        }
    }

    private var whenText: String? {
        guard let date = item.date else { return nil }
        if item.isAllDay { return Calendar.current.isDateInToday(date) ? "today" : date.formatted(.dateTime.weekday(.abbreviated)) }
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
