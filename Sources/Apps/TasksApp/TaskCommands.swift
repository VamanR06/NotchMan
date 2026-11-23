import Foundation
import NotchKit

/// What the command bar can find and do in Tasks: open tasks; check one off; "add …" to add one.
extension TasksApp {
    public func commands(for query: String) -> NotchCommands {
        guard isConnected else { return .none }
        let open = openTasks.prefix(60)
        var items = open.map { task in
            CommandItem(id: "task:" + task.id, title: task.title, subtitle: Self.dueText(task),
                        symbol: "circle", kind: "Task", keywords: [task.databaseTitle]) { [weak self] in
                self?.open(task)
            }
        }
        if let title = Self.quickAddText(query) {
            let parsed = QuickAddParser.parse(title)
            if !parsed.title.isEmpty {
                let when = parsed.date.map { " · " + $0.formatted(date: .abbreviated, time: parsed.hasTime ? .shortened : .omitted) } ?? ""
                items.insert(CommandItem(id: "task.add", title: "Add task: \(parsed.title)\(when)", symbol: "plus.circle",
                                         kind: "Task", keywords: [query]) { [weak self] in
                    Task { await self?.addTask(title: parsed.title, due: parsed.date, allDay: !parsed.hasTime) }
                }, at: 0)
            }
        }
        let checkable = open.filter(canCheckOff)
        let task = CommandParameter(
            name: "task", description: "task",
            choices: checkable.map { CommandChoice(id: $0.id, label: $0.title + (Self.dueText($0).map { " (\($0))" } ?? "")) })
        let title = { (choice: CommandChoice?) in checkable.first { $0.id == choice?.id }?.title ?? "task" }
        let actions = checkable.isEmpty ? [] : [
            CommandAction(id: "complete_task", description: "Check off (complete) a task", risk: .confirm,
                          symbol: "checkmark.circle", parameters: [task], summary: { "Check off “\(title($0["task"]))”" },
                          perform: { [weak self] choices in
                              if let found = checkable.first(where: { $0.id == choices["task"]?.id }) { self?.toggle(found) }
                          }),
        ]
        return NotchCommands(items: items, actions: actions)
    }

    /// The text after "add", "todo" or "task" at the start, if the query starts that way.
    static func quickAddText(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        for prefix in ["add ", "todo ", "task "] where trimmed.lowercased().hasPrefix(prefix) {
            let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    static func dueText(_ task: NotionTask) -> String? {
        guard let due = task.due else { return task.databaseTitle }
        return "Due " + due.formatted(date: .abbreviated, time: task.dueIsAllDay ? .omitted : .shortened)
    }
}
