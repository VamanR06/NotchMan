import Foundation
import NotchKit

/// What one Claude Code session is doing, from the NotchMan bridge mod running inside it (`ClaudeBridge`).
struct SessionActivity: Equatable {
    /// "Editing ShelfView.swift", "Running swift test", "Finished".
    var lastAction: String
    var updated: Date
    /// What you last asked it.
    var lastPrompt: String?
    /// Files it read or changed, newest first.
    var files: [String] = []
    /// Files it changed (Edit/Write), newest first.
    var changedFiles: [String] = []
    var isTurnRunning = false

    /// Recent enough to show as what it's doing now.
    func isFresh(now: Date = Date()) -> Bool { now.timeIntervalSince(updated) < 15 * 60 }
}

/// One signal the bridge mod posts to `/session-signal`.
struct SessionSignal: Decodable, Equatable {
    let event: String
    let session: String
    var cwd: String?
    var tool: String?
    var file: String?
    var command: String?
    var description: String?
    var text: String?
    var aborted: Bool?

    /// How a signal changes what's known about its session.
    func apply(to activity: SessionActivity?, now: Date = Date()) -> SessionActivity {
        var next = activity ?? SessionActivity(lastAction: "Started", updated: now)
        next.updated = now
        switch event {
        case "prompt":
            next.lastPrompt = text
            next.lastAction = "Thinking"
            next.isTurnRunning = true
        case "tool":
            next.lastAction = Self.action(tool: tool ?? "", file: file, command: command, description: description)
            next.isTurnRunning = true
            if let file {
                next.files = Self.front(file, of: next.files)
                if ["Edit", "Write", "NotebookEdit", "MultiEdit"].contains(tool ?? "") { next.changedFiles = Self.front(file, of: next.changedFiles) }
            }
        case "turn.complete":
            next.lastAction = aborted == true ? "Stopped" : "Finished"
            next.isTurnRunning = false
        default:
            break
        }
        return next
    }

    static func action(tool: String, file: String?, command: String?, description: String?) -> String {
        let name = file.map { ($0 as NSString).lastPathComponent }
        switch tool {
        case "Edit", "MultiEdit", "NotebookEdit": return "Editing " + (name ?? "a file")
        case "Write": return "Writing " + (name ?? "a file")
        case "Read": return "Reading " + (name ?? "a file")
        case "Bash": return description.map { $0 } ?? command.map { "Running \(String($0.prefix(40)))" } ?? "Running a command"
        case "Grep", "Glob": return "Searching the code"
        case "WebFetch", "WebSearch": return "Looking things up"
        case "Agent", "Task": return "Running a subagent"
        case "TodoWrite": return "Planning"
        default: return tool.hasPrefix("mcp__") ? "Using \(tool.split(separator: "_").last.map(String.init) ?? "a tool")" : "Using \(tool)"
        }
    }

    private static func front(_ item: String, of list: [String]) -> [String] {
        Array(([item] + list.filter { $0 != item }).prefix(10))
    }
}

extension ChatApp {
    /// Takes signals from the bridge mod (only callers with NotchMan's token reach this).
    func startReceivingSessionSignals() {
        HookServer.shared.route("/session-signal") { [weak self] request in
            guard let signal = try? JSONDecoder().decode(SessionSignal.self, from: request.body) else {
                return HookServer.Response(status: 400)
            }
            await MainActor.run { self?.receive(signal) }
            return .empty
        }
    }

    func receive(_ signal: SessionSignal) {
        sessionActivity[signal.session] = signal.apply(to: sessionActivity[signal.session])
        // Files sessions just changed, for the Shelf and the command bar.
        let changed = sessionActivity.values.filter { $0.isFresh() }.sorted { $0.updated > $1.updated }
            .flatMap(\.changedFiles)
        NotchBoard.shared.agentFiles = Array(NSOrderedSet(array: changed).array.compactMap { $0 as? String }.prefix(10))
            .map { URL(fileURLWithPath: $0) }
    }
}
