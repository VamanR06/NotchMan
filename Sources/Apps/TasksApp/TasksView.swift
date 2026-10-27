import NotchKit
import SwiftUI

struct TasksView: View {
    let app: TasksApp

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Summary(app: app)
                .frame(width: 120, alignment: .leading)

            Rectangle().fill(.white.opacity(0.1)).frame(width: 1)

            if !app.isConnected || !app.databases.contains(where: app.isEnabled) {
                placeholder(
                    app.isConnected ? "Pick a Notion database to show in Settings." : "Connect Notion to see your tasks.",
                    button: true
                )
            } else if app.tasks.isEmpty {
                placeholder(app.isLoading ? "Loading…" : "All caught up.", button: false)
            } else {
                TaskList(app: app)
            }
        }
        .task { await app.refreshIfStale() }
    }

    private func placeholder(_ text: String, button: Bool) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            if button {
                Button("Open Settings", action: app.openSettings).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Summary: View {
    let app: TasksApp

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tasks")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text("\(app.openTasks.count)")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text("open")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 6)
            if app.overdueCount > 0 {
                Label("\(app.overdueCount) overdue", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
            if app.dueTodayCount > 0 {
                Label("\(app.dueTodayCount) due today", systemImage: "sun.max.fill")
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Button { Task { await app.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                if let error = app.error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(error)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
        }
        .font(.system(size: 11))
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct TaskList: View {
    let app: TasksApp

    var body: some View {
        let grouped = Dictionary(grouping: app.tasks, by: app.section(of:))
        let selectedID = app.selectedTask?.id
        let showDatabase = Set(app.tasks.map(\.databaseID)).count > 1
        VStack(spacing: 6) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(TaskSection.allCases, id: \.self) { section in
                        if let tasks = grouped[section] {
                            SwiftUI.Section {
                                ForEach(tasks) { task in
                                    TaskRow(app: app, task: task, overdue: section == .overdue, showDatabase: showDatabase)
                                        .notchSelected(task.id == selectedID)
                                }
                            } header: {
                                HStack {
                                    Text("\(section.title) · \(tasks.count)")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(section == .overdue ? .red.opacity(0.8) : .white.opacity(0.5))
                                        .textCase(.uppercase)
                                    Spacer()
                                    Button("Select") { app.selectAll(in: section) }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.4))
                                        .help("Select every task in \(section.title) to reschedule them together")
                                }
                                .padding(.vertical, 3)
                                .background(.black)
                            }
                        }
                    }
                }
            }
            if app.isSelecting {
                SelectionBar(app: app)
            }
        }
    }
}

private struct TaskRow: View {
    let app: TasksApp
    let task: NotionTask
    let overdue: Bool
    let showDatabase: Bool
    @State private var hovering = false
    @State private var editingDue = false

    var body: some View {
        VStack(spacing: 4) {
            row
            if app.editingTaskID == task.id {
                TaskEditor(app: app, task: task)
            } else if editingDue {
                DueEditor(app: app, task: task) { editingDue = false }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Button { app.toggle(task) } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(task.isDone ? .green : .white.opacity(0.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!app.canCheckOff(task))
            .help(app.canCheckOff(task) ? (task.isDone ? "Mark not done" : "Mark done") : "Set a Done property in Settings to check off tasks")

            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(task.isDone ? 0.4 : 1))
                    .strikethrough(task.isDone)
                    .lineLimit(1)
                if task.due != nil || showDatabase {
                    HStack(spacing: 4) {
                        if let due = task.due {
                            Text(dueText(due))
                                .foregroundStyle(overdue && !task.isDone ? .red.opacity(0.9) : .white.opacity(0.55))
                        }
                        if task.due != nil && showDatabase { Text("·") }
                        if showDatabase { Text(task.databaseTitle).lineLimit(1) }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 4)
            if hovering && !isSelected {
                if app.canEdit(task) {
                    Button { app.editingTaskID = task.id } label: {
                        Image(systemName: "pencil").font(.system(size: 11)).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))
                    .help("Edit (E)")
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? Color.accentColor.opacity(0.35) : .white.opacity(hovering ? 0.08 : 0)))
        .overlay(alignment: .trailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .padding(.trailing, 6)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            // ⇧-click selects a range, ⌘-click (or any click while picking) toggles; otherwise open it.
            let flags = NSEvent.modifierFlags
            if flags.contains(.shift) {
                app.selectRange(to: task)
            } else if flags.contains(.command) || app.isSelecting {
                app.toggleSelection(task)
            } else {
                app.open(task)
            }
        }
        .help(app.isSelecting ? "Click to add or remove; ⇧-click for a range" : "Open in Notion · ⌘-click to select several")
        .contextMenu {
            if isSelected && app.selectedIDs.count > 1 {
                Menu("Reschedule \(app.selectedIDs.count) Tasks") {
                    ForEach(TaskDueOption.allCases) { option in
                        Button(option.title) { app.rescheduleSelection(option) }
                    }
                    Divider()
                    Button("Remove Due Dates") { app.removeDueFromSelection() }
                }
                Button("Clear Selection") { app.clearSelection() }
                Divider()
            } else {
                if app.canEdit(task) {
                    Button("Edit…") { app.editingTaskID = task.id }
                }
                if app.canReschedule(task) {
                    Menu("Reschedule") {
                        ForEach(TaskDueOption.allCases) { option in
                            Button(option.title) {
                                // Tasks with a time keep it; date-only tasks stay date-only.
                                app.reschedule(task, to: option.target(for: task, now: Date()),
                                               allDay: task.due == nil || task.dueIsAllDay)
                            }
                        }
                        Divider()
                        Button("Pick Date…") { editingDue = true }
                        if task.due != nil {
                            Button("Remove Due Date") { app.reschedule(task, to: nil, allDay: true) }
                        }
                    }
                }
                if app.canEdit(task) || app.canReschedule(task) { Divider() }
            }
            AskMenuItems { askText }
        }
    }

    /// What "Ask ChatGPT/Claude/Muse" sends about this task.
    private var askText: String {
        var lines = ["Task: \(task.title)"]
        if let due = task.due {
            lines.append("Due: " + (task.dueIsAllDay ? due.formatted(date: .complete, time: .omitted)
                                                       : due.formatted(date: .complete, time: .shortened)))
        }
        lines.append("From: \(task.databaseTitle) (Notion)")
        if let url = task.url { lines.append("Link: \(url.absoluteString)") }
        return lines.joined(separator: "\n")
    }

    private var isSelected: Bool { app.selectedIDs.contains(task.id) }

    private func dueText(_ due: Date) -> String {
        let calendar = Calendar.current
        let time = task.dueIsAllDay ? "" : " " + due.formatted(date: .omitted, time: .shortened)
        if overdue {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: due), to: calendar.startOfDay(for: app.now)).day ?? 0
            return days == 0 ? "Today\(time)" : days == 1 ? "Yesterday" : "\(days) days ago"
        }
        if calendar.isDateInToday(due) { return task.dueIsAllDay ? "Today" : due.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInTomorrow(due) { return "Tomorrow\(time)" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: app.now), to: due).day ?? 0
        let date = days < 7 ? due.formatted(.dateTime.weekday(.wide)) : due.formatted(.dateTime.month(.abbreviated).day())
        return date + time
    }
}

/// Shown while tasks are selected: move them all at once.
private struct SelectionBar: View {
    let app: TasksApp
    @State private var pickingDate = false

    var body: some View {
        VStack(spacing: 4) {
            if pickingDate {
                BatchDueEditor(app: app) { pickingDate = false }
            }
            HStack(spacing: 6) {
                Text("\(app.selectedIDs.count) selected")
                    .font(.system(size: 11, weight: .semibold))
                if app.reschedulableSelection.count < app.selectedIDs.count {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.white.opacity(0.5))
                        .help("Some selected tasks have no due date property in their database and will be left as they are")
                }
                Spacer(minLength: 4)
                ForEach(TaskDueOption.allCases) { option in
                    chip(short(option)) { app.rescheduleSelection(option) }
                }
                chip("Pick Date…") { pickingDate.toggle() }
                Menu {
                    Button("Remove Due Dates") { app.removeDueFromSelection() }
                    Button("Select All") { app.selectAll() }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Button(action: app.clearSelection) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                    .help("Clear selection (Esc)")
            }
            .disabled(app.reschedulableSelection.isEmpty && !pickingDate)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.1)))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func short(_ option: TaskDueOption) -> String {
        switch option {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .nextMonday: "Next Mon"
        case .pushWeek: "+1 Week"
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}

/// One new date for all selected tasks. Without a time, each task keeps its own time of day.
private struct BatchDueEditor: View {
    let app: TasksApp
    let done: () -> Void
    @State private var date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var includeTime = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            DatePicker("Due", selection: $date, displayedComponents: includeTime ? [.date, .hourAndMinute] : [.date])
                .datePickerStyle(.field)
                .labelsHidden()
                .fixedSize()
            Toggle("Same time for all", isOn: $includeTime)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Spacer()
            Button("Cancel", action: done)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
            Button {
                app.rescheduleSelection(to: date, includeTime: includeTime)
                done()
            } label: {
                Text("Move \(app.reschedulableSelection.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill(.white))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
        .onAppear { app.setEditing(true) }
    }
}

/// Edit a task in place: its title and due date (with or without a time, or none).
private struct TaskEditor: View {
    let app: TasksApp
    let task: NotionTask
    @State private var title: String
    @State private var hasDue: Bool
    @State private var date: Date
    @State private var includeTime: Bool
    @FocusState private var titleFocused: Bool

    init(app: TasksApp, task: NotionTask) {
        self.app = app
        self.task = task
        _title = State(initialValue: task.title)
        _hasDue = State(initialValue: task.due != nil)
        let fallback = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        _date = State(initialValue: task.due ?? fallback)
        _includeTime = State(initialValue: task.due != nil && !task.dueIsAllDay)
    }

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($titleFocused)
                .onSubmit(save)
            HStack(spacing: 8) {
                if app.canReschedule(task) {
                    Toggle("Due", isOn: $hasDue).toggleStyle(.checkbox)
                    if hasDue {
                        DatePicker("Due", selection: $date, displayedComponents: includeTime ? [.date, .hourAndMinute] : [.date])
                            .datePickerStyle(.field)
                            .labelsHidden()
                            .fixedSize()
                        Toggle("Time", isOn: $includeTime).toggleStyle(.checkbox)
                    }
                } else {
                    Text("No due date property in \(task.databaseTitle)").foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Button("Cancel") { app.editingTaskID = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))
                Button(action: save) {
                    Text("Save")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Capsule().fill(.white))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
            .font(.system(size: 11))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
        .onAppear {
            app.setEditing(true)
            titleFocused = true
        }
        .onDisappear { app.setEditing(false) }
        .onExitCommand { app.editingTaskID = nil }
    }

    private func save() {
        guard canSave else { return }
        let due = hasDue ? (includeTime ? date : Calendar.current.startOfDay(for: date)) : nil
        app.edit(task, title: title, due: due, allDay: !(hasDue && includeTime))
    }
}

/// Inline date (and optional time) picker for a task's due date.
private struct DueEditor: View {
    let app: TasksApp
    let task: NotionTask
    let done: () -> Void
    @State private var date: Date
    @State private var includeTime: Bool

    init(app: TasksApp, task: NotionTask, done: @escaping () -> Void) {
        self.app = app
        self.task = task
        self.done = done
        let fallback = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        _date = State(initialValue: task.due ?? fallback)
        _includeTime = State(initialValue: task.due != nil && !task.dueIsAllDay)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            DatePicker("Due", selection: $date,
                       displayedComponents: includeTime ? [.date, .hourAndMinute] : [.date])
                .datePickerStyle(.field)
                .labelsHidden()
                .fixedSize()
            Toggle("Time", isOn: $includeTime)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Spacer()
            Button("Cancel", action: done)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
            Button {
                app.reschedule(task, to: includeTime ? date : Calendar.current.startOfDay(for: date), allDay: !includeTime)
                done()
            } label: {
                Text("Save")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill(.white))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
        .onAppear { app.setEditing(true) }
        .onDisappear { app.setEditing(false) }
    }
}
