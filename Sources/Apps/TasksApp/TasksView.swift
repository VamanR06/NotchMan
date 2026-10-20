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

    private enum Section: Int, CaseIterable {
        case overdue, today, upcoming, noDate

        var title: String {
            switch self {
            case .overdue: "Overdue"
            case .today: "Today"
            case .upcoming: "Upcoming"
            case .noDate: "No due date"
            }
        }
    }

    private func section(of task: NotionTask) -> Section {
        guard let due = task.due else { return .noDate }
        let now = app.now
        let startOfToday = Calendar.current.startOfDay(for: now)
        if task.dueIsAllDay ? due < startOfToday : due < now { return .overdue }
        if Calendar.current.isDateInToday(due) { return .today }
        return .upcoming
    }

    var body: some View {
        let grouped = Dictionary(grouping: app.tasks, by: section(of:))
        let showDatabase = Set(app.tasks.map(\.databaseID)).count > 1
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(Section.allCases, id: \.self) { section in
                    if let tasks = grouped[section] {
                        SwiftUI.Section {
                            ForEach(tasks) { task in
                                TaskRow(app: app, task: task, overdue: section == .overdue, showDatabase: showDatabase)
                            }
                        } header: {
                            Text("\(section.title) · \(tasks.count)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(section == .overdue ? .red.opacity(0.8) : .white.opacity(0.5))
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

private struct TaskRow: View {
    let app: TasksApp
    let task: NotionTask
    let overdue: Bool
    let showDatabase: Bool
    @State private var hovering = false

    var body: some View {
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
            if hovering {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { app.open(task) }
    }

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
