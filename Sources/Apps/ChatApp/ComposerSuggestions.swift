import AppKit
import Foundation
import SwiftUI

/// What the message box offers as you type: Claude Code's slash commands after a leading "/", and the project's files
/// after "@". Picking one completes the word; the text goes to Claude as typed, so it handles them as in its terminal.
struct ComposerSuggestion: Identifiable, Equatable {
    enum Kind { case command, file }
    let kind: Kind
    /// What replaces the word being typed ("/compact ", "@Sources/App.swift ").
    let insert: String
    let title: String
    let detail: String?
    var id: String { insert }
}

enum ComposerSuggestions {
    /// The word being completed: the whole box when it starts with "/" and has no space yet, else the last word if it
    /// starts with "@".
    /// `caret` is where the cursor is (the end when nil): "@" can be typed anywhere in the message, not just last.
    static func token(in draft: String, caret: String.Index? = nil) -> (kind: ComposerSuggestion.Kind, query: String, range: Range<String.Index>)? {
        let caret = caret.map { min($0, draft.endIndex) } ?? draft.endIndex
        let before = draft[..<caret]
        if before.hasPrefix("/"), !before.contains(where: \.isWhitespace) {
            let end = draft[caret...].firstIndex(where: \.isWhitespace) ?? draft.endIndex
            return (.command, String(draft[draft.index(after: draft.startIndex)..<end]), draft.startIndex..<end)
        }
        let start = before.lastIndex(where: \.isWhitespace).map(draft.index(after:)) ?? draft.startIndex
        guard draft[start...].hasPrefix("@") else { return nil }
        // The word runs to the next space after the cursor.
        let end = draft[caret...].firstIndex(where: \.isWhitespace) ?? draft.endIndex
        return (.file, String(draft[draft.index(after: start)..<caret]), start..<end)
    }

    @MainActor
    static func suggestions(for draft: String, caret: String.Index? = nil, folder: String, files: [String]) -> [ComposerSuggestion] {
        guard let token = token(in: draft, caret: caret) else { return [] }
        switch token.kind {
        case .command:
            var scored: [(SlashCommands.Command, Double)] = []
            for command in SlashCommands.all(in: folder) {
                if let value = score(token.query, command.name) { scored.append((command, value)) }
            }
            scored.sort { $0.1 > $1.1 }
            return scored.prefix(6).map { command, _ in
                ComposerSuggestion(kind: .command, insert: "/\(command.name) ", title: "/" + command.name, detail: command.summary)
            }
        case .file:
            var scored: [(String, Double)] = []
            for path in files {
                if let value = score(token.query, path, name: (path as NSString).lastPathComponent) { scored.append((path, value)) }
            }
            scored.sort { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0.count < $1.0.count) }
            return scored.prefix(6).map { path, _ in
                let folder = (path as NSString).deletingLastPathComponent
                return ComposerSuggestion(kind: .file, insert: "@\(path) ", title: (path as NSString).lastPathComponent,
                                          detail: folder.isEmpty ? nil : folder)
            }
        }
    }

    /// The draft with the word being typed replaced by `suggestion`.
    static func apply(_ suggestion: ComposerSuggestion, to draft: String, caret: String.Index? = nil) -> String {
        guard let token = token(in: draft, caret: caret) else { return draft }
        var insert = suggestion.insert
        // Mid-message, don't double the space that follows.
        if token.range.upperBound < draft.endIndex, draft[token.range.upperBound].isWhitespace, insert.hasSuffix(" ") {
            insert.removeLast()
        }
        return draft.replacingCharacters(in: token.range, with: insert)
    }

    /// Where the cursor is in the message box being edited, as an index into `draft`.
    @MainActor static func caret(in draft: String) -> String.Index? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.string == draft else { return nil }
        let location = editor.selectedRange().location
        guard location != NSNotFound, location <= (draft as NSString).length else { return nil }
        return String.Index(utf16Offset: location, in: draft)
    }

    /// Higher is better; nil when it doesn't match. A name starting with the query beats one containing it, which
    /// beats the letters appearing in order.
    static func score(_ query: String, _ text: String, name: String? = nil) -> Double? {
        let query = query.lowercased()
        guard !query.isEmpty else { return 1 }
        let text = text.lowercased(), name = (name ?? text).lowercased()
        if name.hasPrefix(query) { return 4 - Double(name.count) / 1000 }
        if name.contains(query) { return 3 }
        if text.contains(query) { return 2 }
        var rest = Substring(text)
        for character in query {
            guard let found = rest.firstIndex(of: character) else { return nil }
            rest = rest[rest.index(after: found)...]
        }
        return 1
    }
}

/// Claude Code's slash commands: the built-in ones, plus your own commands and skills (in ~/.claude and the project's
/// .claude folder), each with its description.
enum SlashCommands {
    struct Command: Equatable {
        let name: String
        let summary: String
    }

    static let builtIn: [Command] = [
        ("add-dir", "Add a working directory"), ("agents", "Manage subagents"), ("clear", "Start over with an empty conversation"),
        ("compact", "Free up context by summarizing the conversation so far"), ("config", "Open settings"),
        ("context", "Show what fills the context"), ("copy", "Copy the last response to the clipboard"),
        ("cost", "Show what this session has cost"), ("doctor", "Check your Claude Code install"),
        ("effort", "Set how hard Claude thinks"), ("export", "Export the conversation"), ("help", "Show help"),
        ("hooks", "Manage hooks"), ("init", "Write a CLAUDE.md for this project"), ("mcp", "Manage MCP servers"),
        ("memory", "Edit memory files"), ("model", "Switch the model"), ("permissions", "Manage tool permissions"),
        ("plugin", "Manage plugins"), ("pr-comments", "Get a pull request's comments"), ("release-notes", "What's new"),
        ("resume", "Resume an earlier conversation"), ("review", "Review a pull request"),
        ("rewind", "Go back to an earlier point in the conversation"), ("security-review", "Review pending changes for security"),
        ("status", "Show the session's status"), ("tasks", "List background tasks"), ("todos", "Show the current to-do list"),
        ("usage", "Show plan usage and limits"),
    ].map { Command(name: $0.0, summary: $0.1) }

    @MainActor private static var cache: [String: (commands: [Command], at: Date)] = [:]

    /// Built-ins first, then yours; re-read at most every 30 seconds.
    @MainActor static func all(in folder: String) -> [Command] {
        if let cached = cache[folder], Date().timeIntervalSince(cached.at) < 30 { return cached.commands }
        let home = NSHomeDirectory() + "/.claude"
        let project = ClaudeAgentsMonitor.projectFolder(folder) + "/.claude"
        var custom: [Command] = []
        for base in [project, home] {
            custom += commands(in: base + "/commands") + skills(in: base + "/skills")
        }
        var seen = Set<String>()
        let commands = (builtIn + custom).filter { seen.insert($0.name).inserted }
        cache[folder] = (commands, Date())
        return commands
    }

    /// `commands/name.md` and `commands/group/name.md` (as "group:name").
    static func commands(in folder: String) -> [Command] {
        guard let enumerator = FileManager.default.enumerator(atPath: folder) else { return [] }
        return enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".md") }.prefix(200).map { relative in
            let name = String(relative.dropLast(3)).replacingOccurrences(of: "/", with: ":")
            return Command(name: name, summary: description(of: folder + "/" + relative) ?? "Your command")
        }
    }

    /// `skills/name/SKILL.md`.
    static func skills(in folder: String) -> [Command] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.sorted().compactMap { name in
            let file = folder + "/" + name + "/SKILL.md"
            guard FileManager.default.fileExists(atPath: file) else { return nil }
            return Command(name: name, summary: description(of: file) ?? "Your skill")
        }
    }

    /// The `description:` in a Markdown file's front matter, cut to one line.
    static func description(of file: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 4000), as: UTF8.self)
        guard head.hasPrefix("---") else { return nil }
        for line in head.split(separator: "\n").dropFirst() {
            if line.hasPrefix("---") { break }
            if line.hasPrefix("description:") {
                let text = line.dropFirst("description:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                return text.count > 90 ? String(text.prefix(90)) + "…" : text
            }
        }
        return nil
    }
}

/// The project's files, for @-mentions: what git tracks (or, outside a repo, a walk that skips build and dependency
/// folders), listed once in the background and kept for a minute.
@MainActor @Observable
final class ProjectFiles {
    static let shared = ProjectFiles()
    private(set) var files: [String: [String]] = [:]
    @ObservationIgnored private var listedAt: [String: Date] = [:]

    func files(in folder: String) -> [String] {
        if listedAt[folder].map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            listedAt[folder] = Date()
            Task { [weak self] in
                let listed = await Self.list(folder)
                self?.files[folder] = listed
            }
        }
        return files[folder] ?? []
    }

    nonisolated static func list(_ folder: String) async -> [String] {
        if let tracked = try? await Shell.run("/usr/bin/git", ["-C", folder, "ls-files", "--cached", "--others", "--exclude-standard"], timeout: 5) {
            let files = tracked.split(separator: "\n").map(String.init)
            if !files.isEmpty { return Array(files.prefix(20_000)) }
        }
        return await Task.detached(priority: .utility) { walk(folder) }.value
    }

    nonisolated static func walk(_ folder: String) -> [String] {
        let skip: Set<String> = ["node_modules", ".git", ".build", "build", "dist", "DerivedData", "Pods", ".venv", "venv", "__pycache__"]
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: folder),
                                                              includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var files: [String] = []
        let base = URL(fileURLWithPath: folder).standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            if skip.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false else { continue }
            files.append(url.standardizedFileURL.path.replacingOccurrences(of: base, with: ""))
            if files.count >= 5000 { break }
        }
        return files
    }
}

/// The suggestions above the message box: ↑/↓ to move, Tab or Return to take one, Esc to close.
struct SuggestionList: View {
    let suggestions: [ComposerSuggestion]
    let selected: Int
    let pick: (ComposerSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { pick(suggestion) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: suggestion.kind == .command ? "slash.circle" : "doc")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).frame(width: 14)
                        Text(suggestion.title).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                        if let detail = suggestion.detail {
                            Text(detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(index == selected ? Color.accentColor.opacity(0.35) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.13)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.1)))
    }
}

/// Claude's plan for the turn, pinned above the conversation: one line with progress and the step underway; click to
/// see every step.
struct PlanStrip: View {
    let todos: [TodoItem]
    @State private var expanded = false

    var body: some View {
        let done = todos.filter { $0.status == .completed }.count
        let current = todos.first { $0.status == .inProgress } ?? todos.first { $0.status == .pending }
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "checklist").font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                    Text("Plan \(done)/\(todos.count)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                    ProgressView(value: Double(done), total: Double(max(todos.count, 1)))
                        .progressViewStyle(.linear).tint(.green).frame(width: 50)
                    if let current, !expanded {
                        Text(current.title).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 180 : 0)).foregroundStyle(.white.opacity(0.4))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(todos) { todo in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: todo.status == .completed ? "checkmark.circle.fill"
                                  : todo.status == .inProgress ? "circle.dotted.circle" : "circle")
                                .font(.system(size: 9.5))
                                .foregroundStyle(todo.status == .completed ? Color.green : todo.status == .inProgress ? .orange : .white.opacity(0.4))
                            Text(todo.title).font(.system(size: 11))
                                .foregroundStyle(.white.opacity(todo.status == .completed ? 0.45 : 0.85))
                                .strikethrough(todo.status == .completed, color: .white.opacity(0.3))
                        }
                    }
                }
                .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.05)))
    }
}
