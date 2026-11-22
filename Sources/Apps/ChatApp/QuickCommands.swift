import Foundation
import Observation
import SwiftUI

/// Commands you run often in a project (`make run` after each commit), saved per project and shown as buttons in
/// its sessions. Worktrees of a repo share the repo's list.
@MainActor @Observable
final class QuickCommands {
    static let shared = QuickCommands()

    private(set) var byProject: [String: [String]]
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "agents.quickCommands"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        byProject = defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
    }

    func commands(for folder: String) -> [String] {
        byProject[Self.project(folder)] ?? []
    }

    func add(_ command: String, for folder: String) {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        let project = Self.project(folder)
        var list = byProject[project] ?? []
        guard !list.contains(command) else { return }
        list.append(command)
        byProject[project] = list
        save()
    }

    func remove(_ command: String, for folder: String) {
        let project = Self.project(folder)
        byProject[project]?.removeAll { $0 == command }
        if byProject[project]?.isEmpty == true { byProject[project] = nil }
        save()
    }

    func contains(_ command: String, for folder: String) -> Bool {
        commands(for: folder).contains(command.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func save() {
        defaults.set(byProject, forKey: Self.key)
    }

    /// The project a folder belongs to: a worktree under `<repo>/.claude/worktrees/…` counts as `<repo>`.
    static func project(_ folder: String) -> String {
        var path = (folder as NSString).standardizingPath
        if let range = path.range(of: "/.claude/worktrees/") { path = String(path[..<range.lowerBound]) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// The project's quick commands as a row of small buttons above the message box: click one to run it in a shell
/// here (⌥-click: in Terminal); right-click to copy or remove; + saves another.
struct QuickCommandBar: View {
    let folder: String
    @Binding var adding: Bool
    let run: (String) -> Void
    let runInTerminal: (String) -> Void
    @State private var newCommand = ""
    @FocusState private var fieldFocused: Bool
    private var store: QuickCommands { .shared }

    var body: some View {
        let commands = store.commands(for: folder)
        if !commands.isEmpty || adding {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(commands, id: \.self) { command in
                        QuickCommandChip(command: command) {
                            if NSEvent.modifierFlags.contains(.option) { runInTerminal(command) } else { run(command) }
                        }
                        .contextMenu {
                            Button("Run") { run(command) }
                            Button("Run in Terminal") { runInTerminal(command) }
                            Button("Copy") { ShellCommand.copy(command) }
                            Divider()
                            Button("Remove", role: .destructive) {
                                withAnimation(.easeOut(duration: 0.15)) { store.remove(command, for: folder) }
                            }
                        }
                    }
                    if adding {
                        field
                    } else {
                        Button { adding = true } label: {
                            Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.4))
                        .help("Save another command")
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 22)
            .transition(.opacity)
        }
    }

    private var field: some View {
        HStack(spacing: 5) {
            Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundStyle(.orange.opacity(0.8))
            TextField("make run", text: $newCommand)
                .textFieldStyle(.plain)
                .font(.system(size: 10.5, design: .monospaced))
                .frame(width: 170)
                .focused($fieldFocused)
                .onSubmit(commit)
                .onKeyPress(.escape) { cancel(); return .handled }
        }
        .padding(.horizontal, 8).frame(height: 20)
        .background(Capsule().fill(.white.opacity(0.08)))
        .overlay(Capsule().stroke(.white.opacity(0.2)))
        .onAppear { fieldFocused = true }
        .onChange(of: fieldFocused) { _, focused in
            if !focused && newCommand.trimmingCharacters(in: .whitespaces).isEmpty { cancel() }
        }
    }

    private func commit() {
        withAnimation(.easeOut(duration: 0.15)) { store.add(newCommand, for: folder) }
        cancel()
    }

    private func cancel() {
        newCommand = ""
        withAnimation(.easeOut(duration: 0.15)) { adding = false }
    }
}

private struct QuickCommandChip: View {
    let command: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "play.fill").font(.system(size: 7))
                    .foregroundStyle(.white.opacity(hovering ? 0.8 : 0.45))
                Text(command).font(.system(size: 10.5, design: .monospaced)).lineLimit(1)
                    .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.75))
            }
            .padding(.horizontal, 8).frame(height: 20)
            .background(Capsule().fill(.white.opacity(hovering ? 0.12 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Run \(command) in a shell here (⌥-click: in Terminal)")
    }
}
